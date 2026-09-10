# kagent on Amazon EKS

Everything needed to run [kagent](https://kagent.dev) — an AI agent that diagnoses live
Kubernetes clusters — on a real EKS cluster, from scratch.

**Start here: [RUNBOOK.md](RUNBOOK.md).** It assumes no prior knowledge of kagent,
Kubernetes, AWS or Azure, and takes about an hour end to end.

---

## What you get

A Kubernetes cluster on AWS with kagent installed and connected to a language model, plus
a web dashboard where you can ask questions like *"what pods are running?"* or *"why is
this pod failing?"* and get answers derived from the live cluster — not from
documentation, and not guessed.

The runbook also deploys two deliberately broken pods so you can watch it work out what is
wrong with each, including one whose cause is visible only in the container logs.

## What you need

- A Mac or Linux terminal
- An AWS account you can create clusters in
- An Azure OpenAI deployment whose model supports **tool calling** — Appendix A of the
  runbook covers creating one

The model does not have to be in AWS. It is called over the internet with an API key.

## Cost

On a real AWS account, an EKS control plane is roughly $0.10/hour plus two `t3.medium`
instances, billed whether idle or not — so run Step 10 when you are finished.

## The files

| File | Purpose |
|---|---|
| `config.env` | Your settings. **The only file you edit.** |
| `bootstrap-eks.sh` | Creates the EKS cluster. `--probe` checks permissions without creating anything. |
| `setup-model.sh` | Connects the model, proves it can call tools, stores the key in the cluster. |
| `install-kagent.sh` | Installs kagent with Helm. |
| `kagent-values.yaml` | Helm chart settings. |
| `make-lean-agent.sh` | Optional — builds a 5-tool agent to compare against the default 22-tool one. |
| `test-broken-pod.yaml` | Two deliberately broken pods for the diagnosis demo. |
| `uninstall.sh` | Removes kagent. Refuses to run against the wrong cluster. |

**Run order:** `bootstrap-eks.sh` → edit `config.env` → `setup-model.sh` →
`install-kagent.sh`

Every script is safe to re-run.

## Two things that catch people out

**The model must support tool calling.** kagent does nothing else. A model without it
installs perfectly and then answers everything in prose, which looks like broken software.
`setup-model.sh` checks this before anything is installed — if that check fails, stop and
fix it rather than continuing.

**`setup-model.sh` must run before `install-kagent.sh`.** kagent binds its model settings
at install time, so a key added afterwards arrives too late.

## Security notes

- Your API key is never written to disk on your machine. It is typed invisibly and stored
  as a Kubernetes Secret in the cluster.
- `uninstall.sh` refuses to delete anything unless the cluster you are connected to matches
  `EXPECTED_CONTEXT` in `config.env`, and asks you to type the cluster name to confirm.
- The bundled PostgreSQL and the broad permissions here are fine for an evaluation and are
  **not** production settings. See the comments in `kagent-values.yaml`.
