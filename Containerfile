FROM registry.redhat.io/ubi9/ubi-minimal:latest AS base

ENV PROW_JOBS_URL="https://prow.ci.openshift.org/prowjobs.js?omit=annotations,labels,decoration_config,pod_spec"
ENV ARTIFACTS_ROOT_URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/logs"

ENV OCP_MAJOR_VER=4
ENV OCP_MINOR_VER=18
ENV JOB_NAME_REGEX="^periodic-.+-ocp.?$OCP_MAJOR_VER.?$OCP_MINOR_VER-lp-interop.*"

RUN <<EOF
microdnf install jq findutils -y
EOF

FROM base AS get-latest-prowjob-urls
RUN <<EOF 
curl $PROW_JOBS_URL --compressed |
jq -c '[.items[] | select(.spec.job | test(env.JOB_NAME_REGEX))] | 
    .[] | env.ARTIFACTS_ROOT_URL + 
    "/" + .spec.job + "/" + .status.build_id + 
    "/prowjob.json"
' | tee prowjob_urls
EOF

FROM get-latest-prowjob-urls AS fetch-prowjobs
RUN <<EOF
cat prowjob_urls | xargs curl -w '\n' --compressed | 
jq -c '
    .job_name = .spec.job |
    .build_id = .status.build_id |
    .state = .status.state |
    .urls.dashboard = .status.url | 
    .job_short_name = (
                .spec.pod_spec.containers[0].args[] | 
                select(startswith("--target=")) | 
                split("=")[1]
    ) | 
    .urls.firewatch_build_log = env.ARTIFACTS_ROOT_URL + 
        "/" + .job_name + "/" + .build_id + 
        "/artifacts/" + .job_short_name + 
        "/firewatch-report-issues/build-log.txt"
    | {
        job_name,
        job_short_name, 
        build_id, 
        state, 
        urls
    }
' | tee jobs
EOF

FROM fetch-prowjobs AS pre-process
RUN <<EOF
cat jobs | jq -c '
    .urls.firewatch_build_log
' | xargs curl -w "\n\n" | jq -Rs --slurpfile jobs jobs '
    rtrimstr("\n\n") | split("\n\n") |
    [$jobs, .] | transpose | .[] |
    .[0].firewatch_logs=[(.[1] | ltrimstr("\n") | rtrimstr("\n") | split("\n")[] |
        capture(
            "(?<datetime>\\S+)\\s(?<src>\\S+)\\s\\W\\[\\d+m(?<level>ERROR|INFO)\\W\\[\\d+m\\s(?<message>.+)\\W\\[\\d+m$"
        ))] | .[0]
' | tee jobs.tmp
mv jobs.tmp jobs
EOF

FROM pre-process AS post-process
RUN <<EOF
jq -s '.|{jobs: .}' jobs > jobs.json
EOF

ENTRYPOINT ["cat", "jobs.json"]
