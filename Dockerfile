FROM ubuntu:22.04

ARG GH_TOKEN
ARG REPO_URL
ARG RUNNER_NAME

ENV RUNNER_ALLOW_RUNASROOT=1

RUN apt update && \
    apt install -y --no-install-recommends \
    ca-certificates \
    curl \
    tini && \
    apt clean &&\
    rm -rf /var/lib/apt/lists/*

WORKDIR /work
RUN curl -o actions-runner-linux-x64-2.308.0.tar.gz -L https://github.com/actions/runner/releases/download/v2.308.0/actions-runner-linux-x64-2.308.0.tar.gz
RUN tar xzf ./actions-runner-linux-x64-2.308.0.tar.gz
RUN rm ./actions-runner-linux-x64-2.308.0.tar.gz
RUN ./bin/installdependencies.sh
RUN ./config.sh --unattended \
    --name ${RUNNER_NAME} \
    --url ${REPO_URL} \
    --token ${GH_TOKEN}

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["./run.sh"]