# test-self-hosted-runner

GitHub Actions の Self-hosted Runner を試した際のメモ

## References

- <https://docs.github.com/ja/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners>

## Memo

- 様々なレベルで Self-hosted Runner を deploy できる
  - Repository, Organization and Enterprise
- Runner Application は OSS
  - <https://github.com/actions/runner>
  - Linux の System 要件など、<https://github.com/actions/runner/blob/main/docs/start/envlinux.md> にまとまっている
- Runner Application は、job 割り当て時 or 7 日間経過で自動的に latest へ update される
  - 無効にすることもできる
- 14 日以上 GitHub Actions に接続されないと GitHub から自動的に削除される
  - おそらく daemon として上げっぱなしにしておけば削除されない

### 通信周り

- <https://docs.github.com/ja/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners#セルフホストランナーとgithubとの通信>
- HTTPS の long polling を使う
  - 50 sec ごとに connection を張る
- instance -> github.com への connection を張るため、inbound の port を開ける必要はない

### Security

- <https://docs.github.com/ja/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners#self-hosted-runner-security>
  - 第三者が PullRequest を作成することで、任意の workflow (command) を instance 上で実行できる危険性がある
  - `[Repository Settings] - [Actions] - [General]` から、`Actions permissions` と `Fork pull request workflows from outside collaborators` を設定すれば、任意の workflow を実行できなくできる
    - `Allow <username> actions and reusable workflows`: Any action or reusable workflow defined in a repository within <username> can be used.
    - `Require approval for first-time contributors`: Only first-time contributors will require approval to run workflows
- Network 周りでの injection はなさそう

### 自動スケーリング

- <https://docs.github.com/ja/actions/hosting-your-own-runners/managing-self-hosted-runners/autoscaling-with-self-hosted-runners>
- エフェメラルな runner と永続的な runner が存在する
  - default は後者
    - cwd など job で共有される
  - 前者を使う場合、起動時に `--ephemeral` option を追加する
    - Job が終わったら、GitHub Actions から自動的に切り離される
- Job ごとのエフェメラルな runner を立ち上げたい場合は、Webhook を作らなければならない
  - `Workflow Job の起動` -> `GitHub 上での Webhook 受信` -> `Local 環境へ Webhook を転送する` -> `エフェメラルな runner を起動する` という流れを取らなければならない
  - 結構面倒
  - <https://docs.github.com/ja/webhooks-and-events/webhooks/creating-webhooks>
    - `ngrok` と `GitHub CLI` を使って GitHub -> Local の Webhook 転送の例がある
    - inbound の port をインターネットに露出して、Webhook 受け取り用の API Server を立てる必要がある
- k8s controller と terraform module も用意されている
- いずれにせよ、自動スケーリングの構築は割りと工数がかかりそう
- もしくは、永続的な runner をいくつか立てて、runner group を作成しておけば、GitHub Actions が job 振り分け時に load ballance してくれそう (こちらは割りと楽そう)

## Try GitHub Actions Self-hosted Runner

### Environment

```bash
$ cat /etc/os-release
PRETTY_NAME="Ubuntu 22.04.3 LTS"
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION="22.04.3 LTS (Jammy Jellyfish)"
VERSION_CODENAME=jammy
ID=ubuntu
ID_LIKE=debian
HOME_URL="https://www.ubuntu.com/"
SUPPORT_URL="https://help.ubuntu.com/"
BUG_REPORT_URL="https://bugs.launchpad.net/ubuntu/"
PRIVACY_POLICY_URL="https://www.ubuntu.com/legal/terms-and-policies/privacy-policy"
UBUNTU_CODENAME=jammy
$ uname -a
Linux suecharo-server 5.15.0-78-generic #85-Ubuntu SMP Fri Jul 7 15:25:09 UTC 2023 x86_64 x86_64 x86_64 GNU/Linux
$ docker --version
Docker version 24.0.5, build ced0996
```

### Host 環境に直接立てる

`[Repository Settings] - [Actions] - Runners`

<img width="720" alt="スクリーンショット 2023-08-15 16 09 14" src="https://github.com/suecharo/test-self-hosted-runner/assets/26019402/ea71b66e-8352-49c0-a4f1-427cc28e95ff">

OS と Architecture を選択すると、Token 入りのコマンドが表示される

<img width="720" alt="スクリーンショット 2023-08-15 16 13 00" src="https://github.com/suecharo/test-self-hosted-runner/assets/26019402/edfcead4-3e78-4265-a24c-bf6d842e3e95">

```bash
suecharo@srv:~/sandbox$ mkdir actions-runner && cd actions-runner
suecharo@srv:~/sandbox/actions-runner$ curl -o actions-runner-linux-x64-2.307.1.tar.gz -L https://github.com/actions/runner/releases/download/v2.307.1/actions-runner-linux-x64-2.307.1.tar.gz
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
  0     0    0     0    0     0      0      0 --:--:-- --:--:-- --:--:--     0
100  137M  100  137M    0     0  66.1M      0  0:00:02  0:00:02 --:--:-- 72.3M
suecharo@srv:~/sandbox/actions-runner$ echo "038c9e98b3912c5fd6d0b277f2e4266b2a10accc1ff8ff981b9971a8e76b5441  actions-runner-linux-x64-2.307.1.tar.gz" | shasum -a 256 -c
actions-runner-linux-x64-2.307.1.tar.gz: OK
suecharo@srv:~/sandbox/actions-runner$ tar xzf ./actions-runner-linux-x64-2.307.1.tar.gz
suecharo@srv:~/sandbox/actions-runner$ ls -l
total 140824
-rw-rw-r-- 1 suecharo suecharo 144153186 Aug 15 16:14 actions-runner-linux-x64-2.307.1.tar.gz
drwxr-xr-x 4 suecharo suecharo     16384 Jul 25 21:41 bin
-rwxr-xr-x 1 suecharo suecharo      2458 Jul 25 21:40 config.sh
-rwxr-xr-x 1 suecharo suecharo       646 Jul 25 21:40 env.sh
drwxr-xr-x 6 suecharo suecharo      4096 Jul 25 21:41 externals
-rw-r--r-- 1 suecharo suecharo      1487 Jul 25 21:40 run-helper.cmd.template
-rwxr-xr-x 1 suecharo suecharo      2522 Jul 25 21:40 run-helper.sh.template
-rwxr-xr-x 1 suecharo suecharo      2537 Jul 25 21:40 run.sh
-rwxr-xr-x 1 suecharo suecharo        65 Jul 25 21:40 safe_sleep.sh
```

```bash
suecharo@srv:~/sandbox/actions-runner$ ./config.sh --help

Commands:
 ./config.sh         Configures the runner
 ./config.sh remove  Unconfigures the runner
 ./run.sh            Runs the runner interactively. Does not require any options.

Options:
 --help     Prints the help for each command
 --version  Prints the runner version
 --commit   Prints the runner commit
 --check    Check the runner's network connectivity with GitHub server

Config Options:
 --unattended           Disable interactive prompts for missing arguments. Defaults will be used for missing options
 --url string           Repository to add the runner to. Required if unattended
 --token string         Registration token. Required if unattended
 --name string          Name of the runner to configure (default suecharo-server)
 --runnergroup string   Name of the runner group to add this runner to (defaults to the default runner group)
 --labels string        Custom labels that will be added to the runner. This option is mandatory if --no-default-labels is used.
 --no-default-labels    Disables adding the default labels: 'self-hosted,Linux,X64'
 --local                Removes the runner config files from your local machine. Used as an option to the remove command
 --work string          Relative runner work directory (default _work)
 --replace              Replace any existing runner with the same name (default false)
 --pat                  GitHub personal access token with repo scope. Used for checking network connectivity when executing `./run.sh --check`
 --disableupdate        Disable self-hosted runner automatic update to the latest released version`
 --ephemeral            Configure the runner to only take one job and then let the service un-configure the runner after the job finishes (default false)

Examples:
 Check GitHub server network connectivity:
  ./run.sh --check --url <url> --pat <pat>
 Configure a runner non-interactively:
  ./config.sh --unattended --url <url> --token <token>
 Configure a runner non-interactively, replacing any existing runner with the same name:
  ./config.sh --unattended --url <url> --token <token> --replace [--name <name>]
 Configure a runner non-interactively with three extra labels:
  ./config.sh --unattended --url <url> --token <token> --labels L1,L2,L3

suecharo@srv:~/sandbox/actions-runner$ ./config.sh --url https://github.com/suecharo/test-self-hosted-runner --token <token>

--------------------------------------------------------------------------------
|        ____ _ _   _   _       _          _        _   _                      |
|       / ___(_) |_| | | |_   _| |__      / \   ___| |_(_) ___  _ __  ___      |
|      | |  _| | __| |_| | | | | '_ \    / _ \ / __| __| |/ _ \| '_ \/ __|     |
|      | |_| | | |_|  _  | |_| | |_) |  / ___ \ (__| |_| | (_) | | | \__ \     |
|       \____|_|\__|_| |_|\__,_|_.__/  /_/   \_\___|\__|_|\___/|_| |_|___/     |
|                                                                              |
|                       Self-hosted runner registration                        |
|                                                                              |
--------------------------------------------------------------------------------

# Authentication


√ Connected to GitHub

# Runner Registration

Enter the name of the runner group to add this runner to: [press Enter for Default] 

Enter the name of runner: [press Enter for suecharo-server] suecharo-server-hostos

This runner will have the following labels: 'self-hosted', 'Linux', 'X64' 
Enter any additional labels (ex. label-1,label-2): [press Enter to skip] 

√ Runner successfully added
√ Runner connection is good

# Runner settings

Enter name of work folder: [press Enter for _work] 

√ Settings Saved.
```

この時点で、GitHub Actions の Runner 一覧に表示される (Runner を起動していないので status は `Offline`)

<img width="720" alt="スクリーンショット 2023-08-15 16 18 21" src="https://github.com/suecharo/test-self-hosted-runner/assets/26019402/a691754c-3b35-466b-a49a-4763e3fb7170">

```bash
suecharo@srv:~/sandbox/actions-runner$ ./run.sh 

√ Connected to GitHub

Current runner version: '2.307.1'
2023-08-15 07:21:09Z: Listening for Jobs
```

起動した。status が `Idle` になる

<img width="720" alt="スクリーンショット 2023-08-15 16 21 31" src="https://github.com/suecharo/test-self-hosted-runner/assets/26019402/817826f8-a4c4-4e15-82be-377a5fd4f3a0">

適当な tcp が local -> GitHub に張られている

```bash
suecharo@srv:~/sandbox/actions-runner$ netstat -tp | grep Runner
tcp6       0      0 suecharo-server:60624   2620:1ec:21::16:https   ESTABLISHED 110654/Runner.Liste 
```

- この状態で、<https://github.com/suecharo/test-self-hosted-runner/blob/main/.github/workflows/test-workflow.yml> を実行してみる。
  - 実行結果として、<https://github.com/suecharo/test-self-hosted-runner/actions/runs/5864781013/job/15900438101>

また、host では、sapporo の docker container などが立ち上がっている

```bash
suecharo@srv:~/sandbox/actions-runner$ docker ps
CONTAINER ID   IMAGE                                         COMMAND                  CREATED          STATUS          PORTS                                       NAMES
445ccf01a32d   quay.io/commonwl/cwltool:3.1.20220628170238   "/cwltool-in-docker.…"   5 seconds ago    Up 5 seconds                                                ecstatic_gauss
3b264b94eccb   ghcr.io/sapporo-wes/sapporo-service:latest    "tini -- sapporo --r…"   20 seconds ago   Up 20 seconds   0.0.0.0:1122->1122/tcp, :::1122->1122/tcp   yevis-sapporo-service
```

- Job は `./_work/test-self-hosted-runner/test-self-hosted-runner` を `cwd` として、host 側の docker などを使って、実行されている
  - job ごとに workdir が作られる訳では無い
  - また、job 終了後、cleanup される訳でも無い

```bash
suecharo@srv:~/sandbox/actions-runner$ tree _work/
_work/
├── _PipelineMapping
│   └── suecharo
│       └── test-self-hosted-runner
│           └── PipelineFolder.json
├── _temp
├── test-self-hosted-runner
│   └── test-self-hosted-runner
│       ├── test-logs
│       │   ├── c13b6e27-a4ee-426f-8bdb-8cf5c4310bad_1.0.0_test_1.log
│       │   ├── ro-crate-metadata_c13b6e27-a4ee-426f-8bdb-8cf5c4310bad_1.0.0_test_1.json
│       │   └── yevis-log.txt
│       ├── test-results
│       │   └── 49
│       │       └── 4959929b-db93-4f1e-b85a-aab9fb00197e
│       │           ├── cmd.txt
│       │           ├── end_time.txt
│       │           ├── exe
│       │           │   ├── ERR034597_1.small.fq.gz
│       │           │   ├── ERR034597_2.small.fq.gz
│       │           │   ├── fastqc.cwl
│       │           │   ├── trimmomatic_pe.cwl
│       │           │   └── workflow_params.json
│       │           ├── executable_workflows.json
│       │           ├── exit_code.txt
│       │           ├── outputs
│       │           │   ├── ERR034597_1.small_fastqc.html
│       │           │   ├── ERR034597_1.small.fq.trimmed.1P.fq
│       │           │   ├── ERR034597_1.small.fq.trimmed.1U.fq
│       │           │   ├── ERR034597_1.small.fq.trimmed.2P.fq
│       │           │   ├── ERR034597_1.small.fq.trimmed.2U.fq
│       │           │   └── ERR034597_2.small_fastqc.html
│       │           ├── outputs.json
│       │           ├── ro-crate-metadata.json
│       │           ├── run.pid
│       │           ├── run_request.json
│       │           ├── run.sh
│       │           ├── sapporo_config.json
│       │           ├── service_info.json
│       │           ├── start_time.txt
│       │           ├── state.txt
│       │           ├── stderr.log
│       │           ├── stdout.log
│       │           ├── workflow_engine_params.txt
│       │           └── yevis-metadata.yml
│       └── yevis
└── _tool
```

- Runner の remove は、`./config.sh remove` で行える
  - しかし、remove token が必要なため、GitHub Actions の Runner 一覧から remove するのが楽そう

### Docker sibling container として立てる

- 試している人はいくらかいた
  - <https://note.com/shift_tech/n/n199fd81ce315>
  - <https://qiita.com/misohagi/items/077123e4931decbb5ed3>
  - <https://qiita.com/mumoshu/items/02cd9a384d91ce0da198>
- 最初の note のやつが頑張っている
  - config 用の token を発行するために GitHub API を叩く
  - それを使えば、Dockerfile 化できる
- 今回は、もっと雑にかつ、Docker sibling を試してみる
  - docker network は default で作成されるものを使う
  - yevis の制約上、yevis-network に属する container でないといけない

```bash
# ubuntu:22.04 の起動
suecharo@srv:~/sandbox$ mkdir actions-runner-docker
suecharo@srv:~/sandbox$ cd actions-runner-docker/
suecharo@srv:~/sandbox/actions-runner-docker$ mkdir work
suecharo@srv:~/sandbox/actions-runner-docker$ docker network create yevis-network
suecharo@srv:~/sandbox/actions-runner-docker$ docker run -it --rm -v $PWD/work:/work --workdir /work -v /var/run/docker.sock:/var/run/docker.sock --network yevis-network ubuntu:22.04 bash

# docker などの下準備
root@fb3bbce0d0bc:/work# apt update && apt install -y curl
...
root@fb3bbce0d0bc:/work# curl -fsSL -O https://download.docker.com/linux/static/stable/x86_64/docker-24.0.5.tgz
root@fb3bbce0d0bc:/work# tar zxf docker-24.0.5.tgz
root@fb3bbce0d0bc:/work# cp ./docker/* /usr/local/bin/
root@fb3bbce0d0bc:/work# rm -rf ./docker ./docker-24.0.5.tgz
root@fb3bbce0d0bc:/work# docker ps
CONTAINER ID   IMAGE          COMMAND   CREATED         STATUS         PORTS     NAMES
fb3bbce0d0bc   ubuntu:22.04   "bash"    3 minutes ago   Up 3 minutes             distracted_solomon

# GitHub Actions の Runner を起動する
root@fb3bbce0d0bc:/work# curl -o actions-runner-linux-x64-2.307.1.tar.gz -L https://github.com/actions/runner/releases/download/v2.307.1/actions-runner-linux-x64-2.307.1.tar.gz
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
  0     0    0     0    0     0      0      0 --:--:-- --:--:-- --:--:--     0
100  137M  100  137M    0     0  76.5M      0  0:00:01  0:00:01 --:--:-- 81.1M
root@fb3bbce0d0bc:/work# tar xzf ./actions-runner-linux-x64-2.307.1.tar.gz
root@fb3bbce0d0bc:/work# ./config.sh --url https://github.com/suecharo/test-self-hosted-runner --token <token>
Must not run with sudo

# RUNNER_ALLOW_RUNASROOT の flag を立てる
root@fb3bbce0d0bc:/work# export RUNNER_ALLOW_RUNASROOT=1
root@fb3bbce0d0bc:/work# ./config.sh --url https://github.com/suecharo/test-self-hosted-runner --token <token>
Libicu's dependencies is missing for Dotnet Core 6.0
Execute sudo ./bin/installdependencies.sh to install any missing Dotnet Core 6.0 dependencies.

# 依存関係をインストールする
root@fb3bbce0d0bc:/work# ./bin/installdependencies.sh 
--------OS Information--------
...
-----------------------------
 Finish Install Dependencies
-----------------------------
root@fb3bbce0d0bc:/work# ./config.sh --url https://github.com/suecharo/test-self-hosted-runner --token <token>

--------------------------------------------------------------------------------
|        ____ _ _   _   _       _          _        _   _                      |
|       / ___(_) |_| | | |_   _| |__      / \   ___| |_(_) ___  _ __  ___      |
|      | |  _| | __| |_| | | | | '_ \    / _ \ / __| __| |/ _ \| '_ \/ __|     |
|      | |_| | | |_|  _  | |_| | |_) |  / ___ \ (__| |_| | (_) | | | \__ \     |
|       \____|_|\__|_| |_|\__,_|_.__/  /_/   \_\___|\__|_|\___/|_| |_|___/     |
|                                                                              |
|                       Self-hosted runner registration                        |
|                                                                              |
--------------------------------------------------------------------------------

# Authentication


√ Connected to GitHub

# Runner Registration

Enter the name of the runner group to add this runner to: [press Enter for Default] 

Enter the name of runner: [press Enter for fb3bbce0d0bc] suecharo-server-docker

This runner will have the following labels: 'self-hosted', 'Linux', 'X64' 
Enter any additional labels (ex. label-1,label-2): [press Enter to skip] 

√ Runner successfully added
√ Runner connection is good

# Runner settings

Enter name of work folder: [press Enter for _work] 

√ Settings Saved.

# runner を起動する
root@fb3bbce0d0bc:/work# ./run.sh 

√ Connected to GitHub

Current runner version: '2.307.1'
2023-08-15 08:02:03Z: Listening for Jobs
```

起動できたから、再度、<https://github.com/suecharo/test-self-hosted-runner/blob/main/.github/workflows/test-workflow.yml> を実行してみる

Done. <https://github.com/suecharo/test-self-hosted-runner/actions/runs/5865193020/job/15901639772>
