FROM registry.redhat.io/ubi9/ubi-minimal:latest AS base

ENV PROWJOBS_URL="https://prow.ci.openshift.org/prowjobs.js?omit=annotations,labels,decoration_config,pod_spec"
ENV ARTIFACTS_ROOT_URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/logs"
ENV OSCI_CONFIG_ROOT_URL="https://raw.githubusercontent.com/openshift/release/refs/heads/master/ci-operator/config"
ENV JIRA_ROOT_URL="https://issues.redhat.com"
ENV GCS_ROOT_URL="gs://test-platform-results/logs"
ENV OCP_MAJOR_VER=4
ENV OCP_MINOR_VER=19
ENV JOB_NAME_REGEX="periodic-.+-ocp.?$OCP_MAJOR_VER.?$OCP_MINOR_VER-lp-interop.*"

WORKDIR /app
RUN <<EOF
microdnf install jq findutils git -y
microdnf clean all
EOF

FROM base AS base-gcs
COPY --from=gcr.io/google.com/cloudsdktool/google-cloud-cli:alpine /google-cloud-sdk /google-cloud-sdk
RUN <<EOF
ln -s /google-cloud-sdk/bin/gsutil /usr/bin/gsutil
EOF

FROM base AS base-yq
COPY --from=docker.io/mikefarah/yq:latest /usr/bin/yq /usr/bin/yq
RUN <<EOF
EOF

FROM base AS base-src
ENV SPARSE_CHECKOUT_FILENAME_REGEX=ci-operator/**/*.yaml
RUN <<EOF
git clone -n --depth=1 --filter=tree:0   https://github.com/openshift/release.git ./
git sparse-checkout set --no-cone ${SPARSE_CHECKOUT_FILENAME_REGEX}
git checkout
EOF

FROM base-src AS base-src-yq
COPY --from=base-yq /usr/bin/yq /usr/bin/yq
RUN <<EOF
EOF

FROM base-src AS init-db-from-src
RUN <<EOF
grep -Eo $JOB_NAME_REGEX --color=never -rH --include=*.yaml | 
    jq -R '
        split(":") as [$job, $job_name] | 
        {($job_name): {$job_name, osci: {paths: {$job}}}}' | 
    jq -s '
        reduce .[] as $j ({}; .+$j)' > db
EOF

FROM base-src-yq AS get-osci-jobs-from-src
COPY --from=init-db-from-src /app/db .
RUN <<EOF
cat db |
    jq '[.[].osci.paths.job]|unique[]' | 
    xargs yq -o json | 
    jq -s > osci_jobs
jq -cs '
    . as [$db, $jobs] |
    $jobs[].periodics[] | 
    select(.name | in($db))
' db osci_jobs > a.tmp
mv a.tmp osci_jobs
EOF

FROM base AS parse-osci-jobs
COPY --from=get-osci-jobs-from-src /app/osci_jobs .
RUN <<EOF
jq -s '.[] | (.spec.containers|first.args) as $args | 
    ([$args[]|ltrimstr("--")|split("=") as [$key, $value] | 
    [{$key, $value}][]]|from_entries) as $args | {
        (.name): {
            refs: .extra_refs|first, 
            container_args: $args,
        }
    }
' osci_jobs | jq -cs '
    reduce .[] as $j ({}; . + $j) 
' > updates
EOF

FROM base AS update-db-from-osci-jobs
COPY --from=parse-osci-jobs /app/updates .
COPY --from=init-db-from-src /app/db .
RUN <<EOF
jq -s '.[0] * .[1]' updates db > a.tmp
mv a.tmp db
EOF

FROM base AS fetch-min-prowjobs-batch
RUN <<EOF 
curl $PROWJOBS_URL --compressed -s | jq -c > prowjobs_batch
EOF

FROM base AS parse-prowjobs-from-batch
COPY --from=update-db-from-osci-jobs /app/db .
COPY --from=fetch-min-prowjobs-batch /app/prowjobs_batch .
RUN <<EOF
jq -s '
    .[1] as $db | .[0].items as $pj | 
    $pj[] | select(.spec.job | in($db)) as $pj | $pj | 
    {
        (.spec.job): {
            job_name: .spec.job, 
            latest_build_id: .status.build_id, 
            state: .status.state, 
            refs: .spec.extra_refs | first,
            links: {
                prowjob_json: (
                    env.ARTIFACTS_ROOT_URL
                    + "/" + .spec.job + "/" 
                    +.status.build_id + "/prowjob.json"
                ),
                prowjob_json_gcs: (
                    env.GCS_ROOT_URL
                    + "/" + .spec.job + "/" 
                    +.status.build_id + "/prowjob.json"
                ),
            }
        }
    }
' prowjobs_batch db | 
jq -s 'reduce .[] as $j ({}; . + $j)' > updates
EOF

FROM base AS update-db-from-prowjobs-batch
COPY --from=parse-prowjobs-from-batch /app/updates .
COPY --from=update-db-from-osci-jobs /app/db .
RUN <<EOF
jq -s '.[0] * .[1]' updates db > a.tmp
mv a.tmp db
EOF

FROM base-gcs AS get-missing-builds
COPY --from=update-db-from-prowjobs-batch /app/db .
RUN <<EOF
jq '.[]|select(.latest_build_id==null)|@text "\(env.GCS_ROOT_URL)/\(.job_name)/*"' db |
xargs gsutil -qm ls | 
jq -R | 
jq -s '
    .[] | 
    select(endswith(":")) | 
    rtrimstr("/:") | 
    split("/") | {
        job_name: .[-2], 
        latest_build_id: .[-1]
    }
' | jq -s '
    group_by(.job_name) | 
    .[] | 
    [max_by(.latest_build_id)] |
    .[] | {
        (.job_name): {
            job_name,
            latest_build_id,
            links: {
                prowjob_json: (
                    @text "\(env.ARTIFACTS_ROOT_URL)/\(.job_name)/\(.latest_build_id)/prowjob.json"
                ),
                prowjob_json_gcs: (
                    @text "\(env.GCS_ROOT_URL)/\(.job_name)/\(.latest_build_id)/prowjob.json"
                ),
            }
        }
    }
' | jq -s 'reduce .[] as $j ({}; . + $j)' > updates
EOF

FROM base AS update-db-from-missing-builds
COPY --from=update-db-from-prowjobs-batch /app/db .
COPY --from=get-missing-builds /app/updates .
RUN <<EOF
jq -s '.[0] * .[1]' updates db > a.tmp
mv a.tmp db
EOF


FROM base-gcs AS fetch-prowjobs
COPY --from=update-db-from-missing-builds /app/db .
RUN <<EOF
jq '.[]|.links.prowjob_json_gcs|select(.)' db | xargs gsutil -qm cat | jq -c > prowjobs
EOF

FROM base AS parse-prowjobs
COPY --from=fetch-prowjobs /app/prowjobs .
RUN <<EOF
jq -c '
    .job_name = .spec.job |
    .pod_name = .status.pod_name |
    .latest_build_id = .status.build_id |
    .state = .status.state |
    .links.dashboard = .status.url | 
    .job_short_name = (
                .spec.pod_spec.containers[0].args[] | 
                select(startswith("--target=")) | 
                split("=")[1]
    ) |
    .links.firewatch_build_log = (
        env.ARTIFACTS_ROOT_URL + "/" + .job_name 
        + "/" + .latest_build_id + "/artifacts/" 
        + .job_short_name 
        + "/firewatch-report-issues/build-log.txt"
    ) | 
    .links.firewatch_build_log_gcs = (
        env.GCS_ROOT_URL + "/" + .job_name 
        + "/" + .latest_build_id + "/artifacts/" 
        + .job_short_name 
        + "/firewatch-report-issues/build-log.txt"
    ) | 
    .links.ci_operator_log = (
        env.ARTIFACTS_ROOT_URL + "/" + .job_name 
        + "/" + .latest_build_id + "/artifacts/ci-operator.log"
    ) |
    .links.ci_operator_log_gcs = (
        env.GCS_ROOT_URL + "/" + .job_name 
        + "/" + .latest_build_id + "/artifacts/ci-operator.log"
    ) |
    .links.builds_json = (
        env.ARTIFACTS_ROOT_URL + "/" + .job_name 
        + "/" + .latest_build_id + "/artifacts/build-resources/builds.json"
    ) |
    .links.builds_json_gcs = (
        env.GCS_ROOT_URL + "/" + .job_name 
        + "/" + .latest_build_id + "/artifacts/build-resources/builds.json"
    ) |
    .links.build_events_json = (
        env.ARTIFACTS_ROOT_URL + "/" + .job_name
        + "/" + .latest_build_id + "/artifacts/build-resources/events.json"
    ) |
    .links.build_events_json_gcs = (
        env.GCS_ROOT_URL + "/" + .job_name
        + "/" + .latest_build_id + "/artifacts/build-resources/events.json"
    ) |
    .links.pods_json = (
        env.ARTIFACTS_ROOT_URL + "/" + .job_name 
        + "/" + .latest_build_id + "/artifacts/build-resources/pods.json"
    ) |
    .links.pods_json_gcs = (
        env.GCS_ROOT_URL + "/" + .job_name 
        + "/" + .latest_build_id + "/artifacts/build-resources/pods.json"
    ) |
    .links.podinfo = (
        env.ARTIFACTS_ROOT_URL + "/" + .job_name 
        + "/" + .latest_build_id + "/podinfo.json"
    ) |
    .links.podinfo_gcs = (
        env.GCS_ROOT_URL + "/" + .job_name 
        + "/" + .latest_build_id + "/podinfo.json"
    ) |
    {(.job_name): {
            job_name,
            job_short_name, 
            latest_build_id, 
            state, 
            links,
            refs,
            pod_name,
        }
    }
' prowjobs | jq -s 'reduce .[] as $j ({}; . + $j)' > updates
EOF

FROM base AS update-db-from-prowjobs
COPY --from=parse-prowjobs /app/updates .
COPY --from=update-db-from-missing-builds /app/db .
RUN <<EOF
jq -s '.[0] * .[1]' updates db > a.tmp
mv a.tmp db
EOF

FROM base-gcs AS fetch-firewatch-build-logs
COPY --from=update-db-from-prowjobs /app/db .
RUN <<EOF
touch firewatch_build_logs
jq -r '
    .[]| .links.firewatch_build_log_gcs as $uri | 
    [.job_name, $uri] | join(" ")
' db | tr -d \0 | 
while read a b
do
    if [[ -n "$b" ]]
    then
        cat /dev/null > res.gz
        gsutil -qm cat "$b" > res.gz
        if [[ -s res.gz ]] 
        then
            cat res.gz | gzip -dc | 
            jq -R | jq -s '
            {($job_name): {$job_name, firewatch_build_logs: .}}
            ' --arg job_name $a >> firewatch_build_logs
        fi
    fi
done
EOF

FROM base AS parse-firewatch-build-logs
ENV FIREWATCH_BUILD_LOG_CAPTURE_REGEX="(?<datetime>\\S+)\\s(?<src>\\S+)\\s\\W\\[\\d+m(?<level>ERROR|INFO)\\W\\[\\d+m\\s(?<message>.+)\\W\\[\\d+m$"
COPY --from=fetch-firewatch-build-logs /app/firewatch_build_logs .
RUN <<EOF
export FIREWATCH_BUILD_LOG_CAPTURE_REGEX
jq '
    .[] |.firewatch_build_logs = (
            .firewatch_build_logs | map(
                capture(
                    env.FIREWATCH_BUILD_LOG_CAPTURE_REGEX
                )
            )
        ) | {(.job_name): .}
      ' firewatch_build_logs | 
      jq -s 'reduce .[] as $j ({}; . + $j)' > updates
EOF

FROM base AS update-db-from-firewatch-build-logs
COPY --from=update-db-from-prowjobs /app/db .
COPY --from=parse-firewatch-build-logs /app/updates .
RUN <<EOF
jq -s '.[0] * .[1]' updates db > a.tmp
mv a.tmp db
EOF

FROM base-gcs AS fetch-podinfo
COPY --from=update-db-from-prowjobs /app/db .
RUN <<EOF
jq '@text "gsutil -qm cat \(.[].links.podinfo_gcs)"' db | 
    xargs -I '{}' -- bash -c {} | 
    jq -s '@json|fromjson' > podinfo
EOF

FROM base AS parse-podinfo
COPY --from=fetch-podinfo /app/podinfo .
RUN <<EOF
jq '.[] | (
        .pod
        .status
        .containerStatuses[] | 
        select(.name=="test")
    ) as $tc |
{(.pod.metadata.annotations["prow.k8s.io/job"]): {
    pod: {
        pod_status: .pod.status.phase,
        test_container_status: (
            $tc
            .state
            .terminated
            .reason
        ),
        image: $tc.image,
        events: [(.events // [])[] | {type, message}]
    }
}}' podinfo | jq -s 'reduce .[] as $a ({}; .+ $a)' > updates
EOF

FROM base AS update-db-from-podinfo
COPY --from=parse-podinfo /app/updates .
COPY --from=update-db-from-prowjobs /app/db .
RUN <<EOF
jq -s '.[0] * .[1]' updates db > a.tmp
mv a.tmp db
EOF

FROM base-gcs AS fetch-build-events
COPY --from=update-db-from-prowjobs /app/db .
RUN <<EOF
jq '.[].links.build_events_json_gcs as $url | if $url then @sh "gsutil -qm cat \($url) | gzip -d" else "echo null" end' db |
    xargs -I '{}' -- bash -c {} |
    jq -s '@json|fromjson' > a.tmp
jq -s '[(.[0]|keys), .[1]]|transpose|.[]|({(.[0]): .[1]})' db a.tmp |
  jq -s 'reduce .[] as $i ({};.+$i)' > build_events_json
EOF

FROM base AS parse-build-events
COPY --from=fetch-build-events /app/build_events_json .
RUN <<EOF
jq '
map_values({
  atypical_pod_build_events: [
    .items[]?|select(
      .type!="Normal" and .involvedObject.kind=="Pod"
    )|{
        pod_name:.involvedObject.name,
        reason,
        message,
        count,
      }
  ]
})' build_events_json > updates
EOF

FROM base AS update-db-from-build-events
COPY --from=parse-build-events /app/updates .
COPY --from=update-db-from-prowjobs /app/db .
RUN <<EOF
jq -s '.[0] * .[1]' updates db > a.tmp
mv a.tmp db
EOF

FROM base-gcs AS fetch-pods-json
COPY --from=update-db-from-prowjobs /app/db .
RUN <<EOF
jq '@sh "gsutil -qm cat \(.[].links.pods_json_gcs) | gzip -d"' db | 
    xargs -I '{}' -- bash -c {} | 
    jq -s '@json|fromjson' > pods_json
EOF

FROM base AS parse-pods-json
COPY --from=fetch-pods-json /app/pods_json .
RUN <<EOF
jq '
    .[].items as $items | 
    $items | [.[] | {
        name:.metadata.name, 
        status:.status.phase
    }] as $pods | 
     [$items[].metadata.labels["ci.openshift.io/jobid"]|select(.)]|first as $job_id | 
     {$pods, $job_id}
' pods_json > pods
EOF

FROM base AS update-db-from-pods-json
COPY --from=update-db-from-prowjobs /app/db .
COPY --from=parse-pods-json /app/pods .
RUN <<EOF
jq '.[]|[.pod_name, .job_name] | select(all(.)) as [$p, $j] | {($p): $j}' db |
    jq -s 'reduce .[] as $i ({}; .+$i)' > pod_lookup
jq '. as $m | $p[] | {($m[.job_id]): .}' pod_lookup --slurpfile p pods | 
    jq -s 'reduce .[] as $i ({}; .+$i)' > pods_indexed
jq -s '. as [$p, $j] | $p * $j' pods_indexed db > a.tmp
cp a.tmp db
EOF

FROM base AS update-db-from-gathered-artifacts
COPY --from=update-db-from-podinfo /app/db db
COPY --from=update-db-from-firewatch-build-logs /app/db updates
RUN <<EOF
jq -Ss '.[0] * .[1]' updates db > a.tmp
mv a.tmp db
rm -f updates
EOF

FROM update-db-from-gathered-artifacts AS base-post-processing
RUN <<EOF
EOF

FROM base-post-processing AS identify-linked-jira-issues
RUN <<EOF
jq '
    def extract_updates: 
        .jira.linked_issues=[
            (
                .firewatch_build_logs // []
            )[].message |
            match (
                "(.+)\\shas been reported to Jira"; "g"
            ).captures[].string
        ] | {jira};
    
    def transform_jira_issues: 
        .jira.linked_issues[] |= {
            id: ., 
            browser_url: @text "\(env.JIRA_ROOT_URL)/browse/\(.)", 
            reported_by_firewatch: true,
        };
    
    map_values(extract_updates) |  map_values(transform_jira_issues)
' db > updates
EOF

FROM base-post-processing AS verify-jira-ticket-created-for-run
COPY --from=identify-linked-jira-issues /app/updates .
RUN <<EOF
jq -s '.[0] * .[1]' updates db > a.tmp
mv a.tmp db
jq '
    def verify: 
        .verification
        .jira_ticket_created_for_this_run=(
            [
                .jira.linked_issues[]
                .reported_by_firewatch
            ] | any
        ); 
    
    map_values(verify) | map_values({verification})
' db > updates
EOF


FROM base-post-processing AS verify-test-container-started
COPY --from=parse-podinfo /app/updates .
RUN <<EOF
jq -s '.[0] * .[1]' updates db > a.tmp
mv a.tmp db
jq '
    def verify: 
        .verification = {
            test_container_created: (
                [
                    (.pod.events[]
                    .message=="Created container test")?
                ] | any
            ),
            test_container_started: (
                [
                    (.pod.events[]
                    .message=="Started container test")?
                ] | any
            )
        }; 
    
    map_values(verify) | map_values({
        reported_job_state: .state,
        pod_status: .pod.pod_status,
        test_container_status: .pod.test_container_status,
        verification
    })
' db > updates
EOF

FROM base-post-processing AS classify-node-availability-failures
COPY --from=parse-build-events /app/updates .
RUN <<EOF
jq -s '.[0] * .[1]' updates db > a.tmp
mv a.tmp db
jq '
    def classify:
        .classification = {
            scheduling_failed_due_to_node_availability: (
                [
                    (.atypical_pod_build_events[].message |
                        match (
                          "\\d+\\/\\d+ nodes are available:\\s"; "g"
                        )
                    )?
                ] | any
            )
        };

    map_values(classify) | map_values({
        classification
    })
' db > updates
EOF

FROM base-post-processing AS gather-classify-results
COPY --from=classify-node-availability-failures /app/updates classification


FROM base AS gather-verify-results
COPY --from=verify-jira-ticket-created-for-run /app/updates updates_a
COPY --from=verify-test-container-started /app/updates updates_b
RUN <<EOF
jq -sS '.[0] * .[1]' updates_a updates_b > verification
EOF

FROM base AS final
COPY --from=update-db-from-gathered-artifacts /app/db .
COPY --from=gather-verify-results /app/verification .
COPY --from=gather-classify-results /app/classification .
RUN <<EOF
jq -sS '.[0] * .[1]' db verification > a.tmp
jq -sS '.[0] * .[1]' db classification > b.tmp
jq -sS '.[0] * .[1]' a.tmp b.tmp > db
EOF
ENTRYPOINT ["bash", "-c"]