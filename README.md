# mprime Helm chart

Run [mprime](https://www.mersenne.org/download/) (the GIMPS client) on Kubernetes, including
preemptible clusters such as [Rackspace Spot](https://spot.rackspace.com). It uses the image from
[mprime-kubernetes-image](https://github.com/primesearch/mprime-kubernetes-image).

    helm install mprime oci://ghcr.io/primesearch/charts/mprime --version <chart version> \
      --set config.userId=YOUR_MERSENNE_ORG_USER \
      --set replicaCount=2 \
      --set resources.limits.cpu=8 \
      --set resources.requests.memory=16Gi --set resources.limits.memory=16Gi

(or `helm install mprime .` from a checkout). Then `kubectl logs -f mprime-0 -c mprime`. The chart version
(see [Versions](#versions)) is a SemVer *pre-release*, so Helm only finds it if you pass `--version` (or `--devel`).

## How it works

The chart creates a StatefulSet. Each pod is one mprime process:

- **Stable identity.** Pod `n` registers with PrimeNet as the computer `<prefix>-<n>` (prefix defaults to
  the release name). A pod that restarts or moves to another node is the same computer, so it keeps its
  work assignments instead of leaving a trail of abandoned computers.
- **Names that stay put.** The name has to be unique for your PrimeNet account and at most 20 characters, so the
  chart checks it when you install. Set `config.computerIdPrefix` if you run several releases (the default is the
  release name), and keep it short. PrimeNet really identifies a computer by a GUID that mprime keeps in
  `prime.txt`, so the volume is what makes a rescheduled pod the same computer; without `persistence`, the
  name stays but each reschedule registers a new computer. `config.fixedHardwareUid` (on by default) stops
  mprime treating a pod that lands on a different CPU model as new hardware.
- **Its own volume.** Each pod gets a PersistentVolumeClaim mounted at `/mnt/mprime`, holding
  `prime.txt`, `worktodo.txt` and the save files. mprime is started with `-w/mnt/mprime`.
- **Configuration in two steps.** An init container, running the same image, creates `prime.txt` the first time
  and afterwards only sets the keys that come from chart values (see `config`), plus the computer name. Everything
  mprime has added itself (its computer GUID, its bookkeeping) is left alone, which is why changing a value and
  running `helm upgrade` changes the setting without making the pod a new computer. Pods restart when the
  generated configuration changes. Then `start.sh` runs every time the mprime container starts, including after a
  crash or an OOM kill (an init container only runs when the pod is created), works out the settings that depend
  on the node, namely the thread count and the memory, and replaces itself with mprime so that mprime is the
  container's main process and gets SIGTERM.
- **Pre-emption.** mprime writes a checkpoint within about a second of SIGTERM and exits 0. On Rackspace
  Spot, a node that has been outbid is cordoned, then drained about a minute later, then removed. With the
  default `terminationGracePeriodSeconds: 120` and a persistent volume, the pod resumes from its checkpoint.

## Configuration

See [values.yaml](values.yaml); every value is commented. The ones you will most likely change:

| Value | Meaning |
| --- | --- |
| `config.userId` | Your PrimeNet user name. The default `ANONYMOUS` is not credited to you. |
| `config.workPreference` | PrimeNet work type (0 = whatever makes most sense, 4 = P-1, 150 = PRP, ...). |
| `resources` | Empty by default (BestEffort, sized to the node). `limits.cpu` caps the threads (rounded up, never more than the physical cores); `limits.memory` sets how much memory mprime gets. |
| `config.memoryReserveMB`, `config.memoryReservePercent` | What is kept back from the memory limit. `config.memoryMB` sets a fixed amount instead. |
| `config.prime` | Any other `prime.txt` setting. Plain values go at the top; a nested map becomes a `[section]`. |
| `config.usePrimenet=false` | Don't contact PrimeNet; mprime runs only the `worktodo.txt` you put in the pod's volume. |
| `mode` | `statefulset` (default): long-running workers, `replicaCount` of them. `job`: one run of `job.worktodo` that stops when finished (see Job mode). |
| `replicaCount` | Number of pods (StatefulSet mode). |
| `persistence.*` | Volume size, storage class, and whether volumes are kept when you delete the release. |

Any `prime.txt` setting can go in `config.prime`, including per-worker sections (quote names that have spaces):

    config:
      prime:
        DaysBetweenCheckins: 0.5
        "Worker #1":
          Memory: 8000
        PrimeNet:
          MersenneIP: proxy.example.com:8191

Setting and section names are matched without regard to case, as mprime does, so `memory` in `config.prime` replaces
an existing `Memory=` line instead of sitting beside it.

Setting a key in `config.prime` that the chart also sets (for example `NumWorkers`) overrides the chart's value.

### Changing settings

`helm upgrade` with a changed value rewrites that line in each pod's `prime.txt` and restarts the pods.
**Removing** a setting does not remove its line: the init container only adds and replaces. For example,
deleting a `MersenneIP` override leaves workers pointed at the old proxy. To drop a stale line, set it to the
value you want instead, or edit the file in the running pod
(`kubectl exec mprime-0 -c mprime -- sed -i '/^Key=/d' /mnt/mprime/prime.txt`, then delete the pod), or
delete the PVC to start the computer from scratch.

### CPUs

Each pod runs **one** mprime worker that uses all the cores it may use:

- **No resources are set by default.** The pods are then BestEffort: the lowest CPU weight, so mprime gets whatever
  CPU other pods leave idle, and the first to be evicted when the node runs short of memory. That suits a node
  pool that runs little else, such as a dedicated Spot pool, and the chart sizes itself to whatever instance
  it lands on. On a shared cluster, set `resources` to be a better neighbour (see `values.yaml`).
- The thread count is worked out each time mprime starts: the CPU limit rounded up (all the node's CPUs if there is
  no limit), but never more than the **physical cores** the pod can run on. mprime gains nothing from hyperthreads,
  so hyperthread siblings (read from `/sys/devices/system/cpu/*/topology/thread_siblings_list`, which is visible
  in containers) count as one core. With affinity off, the kernel spreads the threads over the cores itself.
- `config.coresPerTest` sets a fixed thread count instead. The chart is built around one worker per pod. If you
  want several, set `NumWorkers` *and* `CoresPerTest` (the cores for each worker) in `config.prime`, otherwise
  every worker gets all the cores and they oversubscribe the CPU.

### CPU affinity and priority

By default mprime pins its threads to CPUs and lowers its own priority (`nice`). Neither fits a shared Kubernetes
node, so:

- **Affinity is off** (`config.enableSetAffinity: false`, which sets `EnableSetAffinity=0`). mprime numbers CPUs
  from 0 using the hardware layout, not the set the pod was given, so two pods on one node would pin to the same
  CPUs. The scheduler's CPU requests are what share a node fairly. Turn affinity on only when a pod owns a whole
  node. With the kubelet's `static` CPU manager policy a pod already gets exclusive CPUs, which makes pinning
  unnecessary.
- **Nice is harmless and left alone.** mprime only ever makes itself nicer, which needs no privileges (the pod
  drops all capabilities). Between pods the CPU share comes from the CPU *requests* (cgroup weights), not from nice,
  so to make mprime yield to other work on a node, use a low CPU request or a PriorityClass. To stop mprime
  calling `nice` at all, set `config.prime.EnableSetPriority: false`.

### Memory

mprime sizes itself from the **node's** RAM, not the pod's memory limit, and by default uses nearly all of it, so
on a large node a pod would be OOM-killed as soon as P-1 stage 2 starts. Its `Memory` setting is also a target,
not a hard limit: it does not read cgroups, and a few things are not counted against it (the program itself,
thread stacks, malloc overhead, the volume's file cache, and brief over-allocation when it re-plans).

So `start.sh` sets `Memory` every time mprime starts (read from the pod spec through the Downward API):

    Memory = resources.limits.memory - config.memoryReserveMB - config.memoryReservePercent%

With **no memory limit**, Kubernetes reports the node's allocatable memory instead, and the script uses what is
actually free right now (`MemAvailable`) if that is less, so a new pod does not take memory other pods on the node
are already using. Keep in mind that memory is not reclaimable like CPU: a BestEffort pod that holds most of a
node's memory is evicted as soon as another pod needs it.

The defaults (1536 MB and 3%) leave about 115 GB of a 120 GB limit to mprime, which suits P-1 stage 2, where
more memory means a larger B2. In a test with stock mprime 30.19 at a 4 GB setting, the container used about 1%
more than the setting. Lower the reserve if you want to squeeze the last bit out, and watch for `OOMKilled`
pods; larger exponents add a little more. `Memory` is shared by all workers in a pod. Set `config.memoryMB` to use
a fixed number instead. Remember the limit has to fit the node: a node's allocatable memory is a little less than
its size. A `Memory` or `CoresPerTest` entry in `config.prime` overrides the calculation.

`config.memoryMinMB` (1024 MB) is a floor set by the chart, not a limit in mprime. P-1 stage 2 needs about 4 MB of
`Memory` per million of the exponent just to run (and much more to run well), and below that mprime does not fail,
it waits without making progress. So if the calculation leaves less than the floor, `start.sh` stops with an error
that says so, and Kubernetes retries it with a back-off. With the default reserve that means a memory limit of about
2 GiB at the very least (mprime is never given less than half of the limit, so the floor only stops pods whose
limit is below 2 GiB); give P-1 stage 2 far more. PRP and LL tests ignore `Memory`: for a pod that only runs them,
set `config.memoryMinMB: 0` and size the memory limit by the exponent (about 15 MB plus 3.5 MB per million of
exponent, measured on mprime 31.7: 350 MB at 100M, 1 GB at 300M).

## Job mode

`mode: job` runs a set of assignments you give it, possibly for weeks, and then **stops by itself**:

    helm install myjob oci://ghcr.io/primesearch/charts/mprime --version <chart version> \
      --set mode=job --set job.slot=p1a --set config.userId=YOUR_MERSENNE_ORG_USER \
      --set-file job.worktodo=worktodo.txt

One release is one job: a Kubernetes Job and a volume, no StatefulSet. `kubectl logs -f job/myjob-mprime -c mprime`
shows it, and `kubectl get job myjob-mprime` shows when it has finished. A Job can't be changed once it is
created: to change one, `helm uninstall` it and install it again.

- **Survives pre-emptions.** A pod that is deleted, drained or pre-empted is replaced by a new pod on the same
  volume, which carries on from mprime's checkpoint. The job's assignments are added to `worktodo.txt` once per
  job, so a replacement pod does not queue the finished ones again. These replacements are not counted against
  `job.backoffLimit`; real failures are.
- **Finished means finished and sent.** mprime itself never stops (with nothing to do it waits for more). The
  start script watches the files and stops mprime, and exits 0, only when `worktodo.txt` has no assignment left and
  nothing is waiting to be sent: no spooled results (`prime.spl`), no proof files (`*.proof`) and no staged P-1
  residues (`p1send.*`, once a proxy has said it accepts them). Uploads need `config.usePrimenet: true`.
  If they are still not sent `job.maxWaitSeconds` (a day) after the last assignment, the job **fails** with the
  files left on the volume, rather than ending as if it had worked. mprime retries a server that is down every
  hour or so, so the wait covers a long outage.
- **A stop is never a success.** mprime exits 0 when it gets SIGTERM, so the start script runs it as a child
  and exits 143 when told to stop; only a finished job exits 0.
- **No new work, and none given back.** Job mode sets `NoMoreWork=1`, so mprime does not queue anything beyond your
  worktodo. `UnreserveDays` is huge (also in the normal mode, `config.unreserveDays`), because with the default
  30 days a month of queued work, or a slow machine, makes mprime hand unstarted assignments back to PrimeNet
  and delete them from `worktodo.txt`.
  **Known problem:** once the queue is empty, `NoMoreWork` makes mprime switch PrimeNet off, and nothing is sent
  after that. A staged P-1 residue (`p1send.*`, from a stage-1-only `Pfactor=` assignment through a proxy) would
  never be uploaded; the job notices and fails with a message saying so. This is a bug in mprime that is being
  fixed in the fork. Until you run that build, set `job.noMoreWork: false` and `DaysOfWork: 0` under
  `config.prime` for those jobs (`DaysOfWork=0` also stops it fetching new work).
- **Slots: reusing a computer.** A job runs as the PrimeNet computer `kube-job-<slot>`, and its volume is named the
  same. `job.slot` defaults to the release name, which makes a new computer for every job. Give it a name (lower
  case letters, digits and `-`, 11 characters at most with the default prefix) and later jobs with that slot find
  the kept volume and continue as the same computer, with the same GUID; the volume is kept when you uninstall
  (`job.keepVolume`), and `kubectl delete pvc kube-job-<slot>` removes it. One job at a time per slot; the chart
  refuses a slot that another running job holds (it checks against the cluster, not with `helm template`).
- **The assignments.** `job.worktodo` is the text of a `worktodo.txt`; every line is run in order. For P-1 through
  a proxy, a stage-1-only job needs `Pfactor=` lines (a `Pminus1=` line is not staged for upload) and a small
  per-worker `Memory` below the stage 2 minimum, set under `config.prime`. Lines without a PrimeNet assignment ID
  are registered with the server at start; whether it accepts results for them is up to the server or proxy.
- **For a month of pre-emptions** use the default `config.fixedHardwareUid` so that a different CPU after a pre-emption
  is not a new computer, and test volume re-attach on your Spot cluster first (see Rackspace Spot notes).

## Several clusters

Computer names must be unique across everything using your PrimeNet account, and a Helm release name is only
unique inside one cluster and namespace. Installing `helm install mprime ...` in two clusters would give both
a `mprime-0`. Give each cluster a short tag with `config.clusterName`:

    helm install mprime ... --set config.clusterName=iad      # computers mprime-iad-0, mprime-iad-1, ...
    helm install mprime ... --set config.clusterName=dfw      # computers mprime-dfw-0, ...

or keep one small values file per cluster. `config.computerIdPrefix` replaces the whole prefix if you prefer.
PrimeNet names are at most 20 characters including the `-<pod number>`, and the chart refuses to install with a
longer one, so keep the tag short. Kubernetes has no standard cluster name that a chart could read, which is why
this is a value you set.

## Rackspace Spot notes

- **Storage.** Only `ReadWriteOnce` volumes are available, and the size limits depend on the storage class
  (Gen-1 `ssd`: 5-20 GB; Gen-2 `ssdv2-performance`: 10 GB and up). The default 10 Gi works with either.
  Set `persistence.storageClass` to choose one. A PRP test also needs temporary disk space for its proof
  (several GB for large exponents), so make sure `persistence.size` has room for it.
  Volumes are billed until the PVC is deleted, which is why `persistence.retentionPolicy` defaults to
  `Retain`: delete the PVCs yourself (`kubectl delete pvc -l app.kubernetes.io/instance=<release>`) when you
  are finished, or set both policies to `Delete`.
- **Not yet verified on a real Spot cluster:** that a volume re-attaches when its pod is rescheduled after
  a node is pre-empted. The Rackspace documentation does not describe it. If pods get stuck in
  `ContainerCreating` after a pre-emption, the documented workaround for a stuck attach is to recycle the node.
- **Taints and node selectors.** Use `tolerations` and `nodeSelector` as your node pool requires.
- **CPU features.** The stock mprime build picks its FFT code at run time from the CPU's features, so the
  chart needs no per-CPU settings.

## Upgrading

`helm upgrade` replaces the pods one at a time; each new pod resumes from its checkpoint on the same volume
(mprime upgrades its own files in place, also from an older release). Two things to know:

- **Volume settings can't change in place.** Kubernetes does not allow changing a StatefulSet's volume claim
  templates, so `persistence.size`, `persistence.storageClass`, `persistence.accessModes`, switching
  `persistence.enabled` on or off, and changing `nameOverride` or `fullnameOverride` make `helm upgrade` fail with
  "updates to statefulset spec for fields other than ... are forbidden". To grow the volumes, resize the PVCs
  yourself if the storage class allows it, then `kubectl delete statefulset <name> --cascade=orphan` (the pods and
  volumes stay) and run `helm upgrade`, which recreates the StatefulSet.
- **Always pass `--version`** when installing or upgrading from the registry, as above.

## Using a P-1 proxy

Point mprime at the proxy through `prime.txt` (this is what a patched mprime reads):

    config:
      prime:
        PrimeNet:
          MersenneIP: proxy.example.com:8191

This is only a settings pass-through for now: the chart does not deploy a proxy, does not set up TLS or
authentication, and the stock mprime image does not use proxy features.

## Development

    helm lint .
    helm template test . | less

## Versions

The chart version is the mprime version written as SemVer (30.19 build 20 is `30.19.20`) plus our own revision,
like `-ubuntu1` on a Debian package: `30.19.20-primesearch.1`. Raise the number for chart-only changes and reset
it for a new mprime version. (The dot makes SemVer compare the revision as a number.) The `appVersion` is the
exact image tag the chart deploys, for example `30.19b20-primesearch.1`.

To release: set `version` and `appVersion` in `Chart.yaml`, merge to `main`, then tag that commit with exactly the
chart version and push the tag. The workflow publishes the chart to `oci://ghcr.io/primesearch/charts/mprime`.
