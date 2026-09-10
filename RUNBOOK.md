# Running kagent on Amazon EKS

A complete, start-to-finish guide. **No prior knowledge of kagent, Kubernetes, AWS or
Azure is assumed.** Every step says what to run, what you should see, and what it means
if you see something else.

**Time:** about 60 minutes, most of it waiting for AWS to build the cluster.

---

## What you are building, and why

**kagent** is an AI agent that runs *inside* a Kubernetes cluster and answers questions
about it — "what pods are running?", "why is this one failing?" — by calling real
Kubernetes APIs rather than guessing. It is not a chatbot with documentation; it inspects
the live cluster.

By the end you will have:

- A real Kubernetes cluster running on AWS (EKS)
- kagent installed on it, wired to a language model
- A web dashboard where you can ask it questions
- Two deliberately broken pods, so you can watch it diagnose real failures

```
   Your laptop                AWS                        Azure
   ───────────                ───                        ─────
   kubectl / helm  ────────►  EKS cluster                Azure OpenAI
   web browser     ────────►    └─ kagent  ──────────►     (the model)
                                    └─ asks the
                                       Kubernetes API
```

**Three things are involved and they are easy to confuse:**

| Thing | What it does |
|---|---|
| **Your laptop** | Runs the commands. Nothing is installed on a server; you drive everything from here. |
| **AWS** | Hosts the Kubernetes cluster that kagent runs on. |
| **Azure OpenAI** | Hosts the *model* kagent thinks with. It is reached over the internet with a key — it does not need to be in AWS, and the two clouds never talk to each other directly. |

---

## Before you start

You need **four** things. Get them all before running anything — stopping halfway to hunt
for a credential is where most of the lost time goes.

### 1. A Mac or Linux machine with a terminal

Every command here is written for a Unix shell.

### 2. An AWS account you are allowed to create clusters in

A normal AWS account works for this guide. You need an IAM user or role credentials:
**access key ID** and **secret access key** (see Step 1).

> **This costs real money.** An EKS control plane bills roughly $0.10/hour plus the EC2
> nodes, whether you use it or not. **Do Step 10 when you are finished.**

### 3. An Azure OpenAI deployment with tool calling

You need four values from it — endpoint, deployment name, model name, and API key.
See **Appendix A** if you do not have one yet.

### 4. This folder

All the scripts referenced below live in it. Open a terminal and `cd` into it now:

```bash
cd path/to/AWS
chmod +x *.sh
```

---

## Step 1 — Get your AWS credentials

Use a normal AWS account and create credentials for the AWS CLI.

1. Sign in to the AWS Console in the account you want to use.
2. Open **IAM** and create (or choose) an IAM user for this demo.
3. Grant permissions to create EKS clusters, IAM roles, and CloudFormation stacks.
   - For a test account, attaching `AdministratorAccess` is the simplest option.
4. Create an **Access Key ID** and **Secret Access Key** for that IAM user.
5. Save both values now (you will enter them in Step 3).
6. Pick the AWS region you will use for the cluster (recommended: `us-east-1`) and stay
   consistent with it through all steps.

Do not use the root account access keys for this guide.

---

## Step 2 — Install the tools

Four command-line tools. On macOS with [Homebrew](https://brew.sh):

```bash
brew install awscli eksctl kubectl helm
```

On Linux, follow each project's install guide — `awscli`, `eksctl`, `kubectl`, `helm`.

Check they are all there:

```bash
aws --version
eksctl version
kubectl version --client
helm version --short
```

**What each one is for:**

| Tool | Purpose |
|---|---|
| `aws` | Talks to AWS. Holds your credentials. |
| `eksctl` | Creates the EKS cluster. Does in one command what would otherwise be dozens. |
| `kubectl` | Talks to Kubernetes. You will use this constantly. |
| `helm` | Installs applications into Kubernetes. kagent ships as a Helm chart. |

---

## Step 3 — Point the AWS CLI at your account

```bash
aws configure
```

It asks four questions:

```
AWS Access Key ID     : (paste from Step 1)
AWS Secret Access Key : (paste from Step 1)
Default region name   : us-east-1        <- use YOUR sandbox's region
Default output format : json
```

Check it worked:

```bash
aws sts get-caller-identity
```

**You should see** JSON containing an `Account` number and an `Arn`. If you get
`Unable to locate credentials`, the keys did not save — run `aws configure` again.

---

## Step 4 — Create the cluster

First, a dry run. This **creates nothing** and checks whether your account will actually
let you build a cluster:

```bash
./bootstrap-eks.sh --probe
```

**You should see** a list of `[ok]` lines ending with *"Recon found no blockers"*.

If it stops with `[no]`, read the message — it will tell you which permission is missing.
The usual cause is an account that cannot create IAM roles, which EKS requires.

Now build it:

```bash
./bootstrap-eks.sh
```

**This takes 15–20 minutes.** That is normal — AWS is creating a virtual network, a
Kubernetes control plane, and two servers. There will be long pauses with no output.
Leave it alone; do not press Ctrl-C.

**You should see**, at the end:

```
  cluster         kagent-rehearsal
  region          us-east-1
  nodes           2 x t3.medium
  context         arn:aws:eks:us-east-1:123456789012:cluster/kagent-rehearsal
```

**Copy that `context` line — you need it in the next step.**

<details>
<summary>What the script actually did, if you are curious</summary>

- Created a VPC (a private network) with public and private subnets across two
  availability zones
- Created the EKS control plane — the Kubernetes "brain", managed by AWS
- Created two `t3.medium` EC2 instances as worker nodes
- Installed the **EBS CSI driver**, which lets Kubernetes create disks on AWS. This
  matters: EKS ships a default storage setting that no longer works, and without this
  driver kagent's database would wait forever for a disk that never arrives.
- Set up a working default storage class (`gp3-csi`)
- Wrote the cluster's connection details into `~/.kube/config` so `kubectl` can reach it

</details>

---

## Step 5 — Fill in the configuration

Open `config.env` in any text editor. Fill in **four** values:

```bash
EXPECTED_CONTEXT="arn:aws:eks:..."     # paste the context line from Step 4

AOAI_ENDPOINT="https://YOUR-RESOURCE.openai.azure.com/"
AOAI_DEPLOYMENT="your-deployment-name"
AOAI_MODEL="your-model-name"
```

`CLUSTER_NAME` and `AWS_REGION` are already correct and are further down the file. Change
them only if you passed different values to `bootstrap-eks.sh` in Step 4 — the cluster
already exists by now, so editing them here does not rename anything. `uninstall.sh` uses
them to confirm which cluster it is about to touch.

**Do not put the API key in this file.** The next step asks for it and stores it safely.

Two things people get wrong here:

- **`EXPECTED_CONTEXT` must be the full ARN**, exactly as printed — not the short cluster
  name. It is a safety check that stops you accidentally deleting a different cluster, and
  it compares the text character for character.
- **`AOAI_ENDPOINT` must be the bare hostname with a trailing slash.** If Azure showed you
  something ending in `/openai/v1/responses`, that is a different API and will not work.
  Use `https://<resource-name>.openai.azure.com/`.

---

## Step 6 — Connect the model, and prove it works

Check the model answers before storing anything:

```bash
./setup-model.sh --verify-only
```

That runs the two tests below and creates nothing. When both pass, run it for real:

```bash
./setup-model.sh
```

It reads everything except the key from `config.env`, then asks for the key. **The key
will not appear on screen as you type** — that is deliberate, not a frozen terminal. Paste
it and press Enter.

It then runs two tests. **Both must pass:**

```
[ok] endpoint, key and deployment name all good
[ok] model emitted a tool call -> k8s_get_resources
```

**The second test is the important one.** It checks that the model can *call tools*, not
just chat. kagent does nothing but call tools, so a model that cannot will install
perfectly and then answer every question in prose — which looks like broken software when
it is actually the wrong model or the wrong API version.

**If test 2 fails**, do not continue. Read the message — it tells you what to change,
usually the API version in `config.env`.

**What this step does with your key:** stores it inside the cluster as a Kubernetes
Secret. It is never written to a file on your laptop.

---

## Step 7 — Install kagent

```bash
./install-kagent.sh
```

Takes 2–3 minutes.

> **Order matters.** `setup-model.sh` must run before this. kagent reads its model
> settings when the installation is created, so a key added afterwards arrives too late
> and you will see `secret not found` errors.

**You should see** roughly 5 pods and four confirmation lines:

```
[ok] provider is AzureOpenAI
[ok] endpoint is https://your-resource.openai.azure.com/
[ok] deployment is your-deployment
[ok] apiVersion is 2024-12-01-preview
```

Check for yourself:

```bash
kubectl get pods -n kagent
```

**You should see** about 5 pods, all `Running`:

```
NAME                                 READY   STATUS    RESTARTS   AGE
k8s-agent-...                        1/1     Running   0          2m
kagent-controller-...                1/1     Running   0          2m
kagent-postgresql-...                1/1     Running   0          2m
kagent-tools-...                     1/1     Running   0          2m
kagent-ui-...                        1/1     Running   0          2m
```

| If you see | It means |
|---|---|
| `Pending` | Not enough room on the nodes. Check `kubectl describe pod <name> -n kagent`. |
| `ImagePullBackOff` | The cluster cannot download kagent's images — a network/firewall issue. |
| `CrashLoopBackOff` on the controller | Often just startup order; it retries. Give it two minutes. |
| 18+ pods instead of 5 | The settings file did not apply. Check you ran the script from this folder. |

---

## Step 8 — Open the dashboard

kagent's web interface runs inside the cluster and is not exposed to the internet. To
reach it, forward a port from the cluster to your laptop:

```bash
kubectl port-forward -n kagent svc/kagent-ui 8080:8080
```

**Leave this running.** It occupies the terminal — that is correct. Open a **second**
terminal for anything else.

Now open **<http://localhost:8080>** in your browser.

> **If the browser cannot connect**, the port-forward has stopped. It does not survive a
> closed terminal or a laptop sleeping. Just run it again.

---

## Step 9 — Ask it something

In the dashboard, select the **k8s-agent** agent and ask:

> What pods are running in my cluster?

**You should get** a real answer in a few seconds, listing pods across the `kagent` and
`kube-system` namespaces.

Check it is telling the truth — in your second terminal:

```bash
kubectl get pods -A
```

The lists should match. **That is the point of the demo**: the agent called a live API,
it did not produce a plausible-sounding guess.

### Watch it diagnose real failures

Deploy two deliberately broken pods:

```bash
kubectl apply -f test-broken-pod.yaml
kubectl get pods -n kagent-demo
```

Wait about a minute, until you see:

```
NAME              READY   STATUS             RESTARTS
broken-config-…   0/1     CrashLoopBackOff   3
broken-image-…    0/1     ImagePullBackOff   0
```

Now ask the agent — **start a new chat first**, so old conversation does not confuse it:

> There are pods failing in the kagent-demo namespace. What is wrong with each one and how
> do I fix them?

**A correct answer identifies both, and they are deliberately different difficulties:**

| Pod | Failure | Why it is broken | How hard |
|---|---|---|---|
| `broken-image` | `ImagePullBackOff` | Its image tag does not exist | **Easy** — visible in the pod's events |
| `broken-config` | `CrashLoopBackOff` | Exits immediately; a config file is missing | **Hard** — the reason exists *only* in the container's logs |

The second one is the real test. The pod's status only says "it keeps restarting" — to
find out *why*, the agent has to go and read the container logs, which is a different tool
call. **A good answer quotes the missing file path, `/etc/app/config.yaml`.** If it just
says "the container is crashing", it looked at the status and guessed.

### Optional — the cost demo

```bash
./make-lean-agent.sh
```

This creates a second agent, `k8s-lean`, with 5 tools instead of 22 — otherwise identical.
Ask it the same question.

Why this matters: an agent sends the full description of every tool it has to the model on
**every single turn**. 22 tools is roughly 2,250 tokens re-sent every time, and you are
billed for all of it. If a 5-tool agent answers the question just as well, the other 17
tool descriptions were pure recurring cost.

---

## Step 10 — Shut it down

**Do not skip this on a real AWS account.** The cluster bills by the hour.

Remove kagent:

```bash
./uninstall.sh
```

It shows you what it is about to delete and asks you to type the cluster name to confirm.
It refuses to run at all unless `EXPECTED_CONTEXT` matches the cluster you are currently
connected to.

Then delete the cluster itself:

```bash
eksctl delete cluster --name kagent-rehearsal --region us-east-1
```

**This takes 10–15 minutes** and removes the network, nodes and control plane. Confirm it
is gone:

```bash
aws eks list-clusters --region us-east-1
```

**You should see** an empty list.

> Cleanup is essential on a real account. Leaving the cluster running is the difference
> between a short test and an unexpected bill.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Unable to locate credentials` | AWS CLI not configured | `aws configure` again |
| `--probe` fails on IAM | Account cannot create IAM roles | Use an account that can; EKS requires it |
| `eksctl create cluster` fails | Permissions, quota, or expired sandbox | Read the CloudFormation error. Clean up with `eksctl delete cluster` before retrying |
| Key typed but nothing appears | Working as intended | Keys are hidden while typing. Paste and press Enter |
| `HTTP 401` from setup-model.sh | Wrong key, or extra characters pasted | Re-copy the key |
| `HTTP 404` from setup-model.sh | Deployment name wrong, or wrong endpoint form | Check the deployment name in Azure; endpoint must be `https://<name>.openai.azure.com/` |
| `HTTP 200` but "no tool_calls" | Model or API version does not support tool calling | Try `AOAI_API_VERSION="2025-03-01-preview"`, or use a model that supports function calling |
| `secret not found` on pods | `install-kagent.sh` ran before `setup-model.sh` | `./uninstall.sh`, then Steps 6 and 7 in order |
| PostgreSQL pod stuck `Pending` | No working storage | `kubectl get storageclass` — `gp3-csi` should be `(default)` |
| Browser cannot reach `localhost:8080` | Port-forward stopped | Run the `port-forward` command again |
| Agent answers but never calls tools | Old chat with history | Start a new chat |
| `uninstall.sh` refuses to run | You are connected to a different cluster | That is the guard working. Check `kubectl config current-context` |

**Two commands worth knowing:**

```bash
kubectl config current-context      # which cluster am I actually talking to?
kubectl get pods -A                 # what is running, everywhere
```

The first one matters a lot if you have more than one cluster. Every `kubectl` and `helm`
command goes to whatever that prints.

---

## Appendix A — Creating an Azure OpenAI deployment

Skip this if someone has already given you an endpoint, deployment name, model name and
key.

1. Sign in at <https://portal.azure.com>
2. Search for **Azure OpenAI** and open (or create) a resource. Note its **name**.
3. Open **Model deployments** → **Deploy model** → **Deploy base model**
4. **Pick a model that supports tool calling / function calling.** This is not optional —
   kagent cannot work without it. Current general-purpose chat models do; models
   specialised for code completion often do not. A "mini" or small tier is fine and
   cheaper.
5. Give the deployment a name you will recognise. Note it — this is `AOAI_DEPLOYMENT`.
   The model it serves is `AOAI_MODEL`.
6. Open **Keys and Endpoint**. Copy **KEY 1**.

Your endpoint is `https://<resource-name>.openai.azure.com/` — the bare hostname with a
trailing slash.

> If the portal shows you a URL ending in `/openai/v1/responses`, ignore it. That is a
> different API with a different request format. Use the `openai.azure.com` form above.

---

## Appendix B — What each file does

See [the file table in README.md](README.md#the-files). All of the scripts are safe to
re-run.
