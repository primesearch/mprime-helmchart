{{/*
Where the volume and the scripts are mounted, in both containers. They are passed to the scripts as
MPRIME_DIR and SCRIPTS. They are not values: the image runs mprime with -w/mnt/mprime and its CMD uses the
same directory.
*/}}
{{- define "mprime.dataDir" -}}/mnt/mprime{{- end }}
{{- define "mprime.scriptsDir" -}}/scripts{{- end }}

{{/* PrimeNet computer names are at most this many characters. */}}
{{- define "mprime.maxComputerNameLength" -}}20{{- end }}

{{/* Chart name, truncated to a valid DNS label length. */}}
{{- define "mprime.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified name for the StatefulSet and its pods (<name>-0, <name>-1, ...). At most 52 characters:
     a pod's controller-revision-hash label is <name>-<hash> and a label value may have 63. */}}
{{- define "mprime.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 52 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 52 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 52 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "mprime.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "mprime.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "mprime.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mprime.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "mprime.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/* Render a prime.txt value: booleans become 1/0, whole numbers are printed without an exponent or
     decimal point (Helm parses all YAML numbers as floats), everything else is printed as is. */}}
{{- define "mprime.value" -}}
{{- if kindIs "bool" . }}{{ ternary 1 0 . }}{{ else if and (kindIs "float64" .) (eq . (float64 (int64 .))) }}{{ . | int64 }}{{ else }}{{ . }}{{ end }}
{{- end }}

{{/* A config.prime key or section name: it ends up before an '=' or inside [ ], on one line. */}}
{{- define "mprime.primeKey" -}}
{{- if regexMatch "[=\n\r\t]" . -}}
{{- fail (printf "config.prime key %q must not contain '=', a tab or a newline." .) -}}
{{- end -}}
{{- . -}}
{{- end }}

{{/* A config.prime value, as one line (the settings file has one setting per line). */}}
{{- define "mprime.primeValue" -}}
{{- if or (kindIs "map" .) (kindIs "slice" .) -}}
{{- fail "config.prime values must be single values, or a map of single values for a [section]." -}}
{{- end -}}
{{- $v := include "mprime.value" . -}}
{{- if regexMatch "[\n\r\t]" $v -}}
{{- fail (printf "config.prime value %q must not contain a tab or a newline." $v) -}}
{{- end -}}
{{- $v -}}
{{- end }}

{{/*
The settings the init container keeps in step with the chart values, one per line as
"<section><TAB><key><TAB><value>". The section "-" is the top of prime.txt (before any [section]).
Anything under config.prime comes last, so it wins. A map under config.prime is a [section].
*/}}
{{- define "mprime.managed" -}}
{{- $c := .Values.config -}}
{{- printf "-\tUsePrimenet\t%s\n" (include "mprime.value" $c.usePrimenet) -}}
{{- if $c.usePrimenet }}
{{- printf "-\tV5UserID\t%s\n" (include "mprime.value" $c.userId) -}}
{{- printf "-\tWorkPreference\t%s\n" (include "mprime.value" $c.workPreference) -}}
{{- printf "-\tFixedHardwareUID\t%s\n" (include "mprime.value" $c.fixedHardwareUid) -}}
{{- end }}
{{- printf "-\tNumWorkers\t1\n" -}}
{{- printf "-\tUnreserveDays\t%s\n" (include "mprime.value" $c.unreserveDays) -}}
{{- if and (eq .Values.mode "job") .Values.job.noMoreWork }}
{{- printf "-\tNoMoreWork\t1\n" -}}
{{- end }}
{{- printf "-\tEnableSetAffinity\t%s\n" (include "mprime.value" $c.enableSetAffinity) -}}
{{- range $key, $val := $c.prime }}
{{- if kindIs "map" $val }}
{{- range $k2, $v2 := $val }}
{{- printf "%s\t%s\t%s\n" (include "mprime.primeKey" $key) (include "mprime.primeKey" $k2) (include "mprime.primeValue" $v2) -}}
{{- end }}
{{- else }}
{{- printf "-\t%s\t%s\n" (include "mprime.primeKey" $key) (include "mprime.primeValue" $val) -}}
{{- end }}
{{- end }}
{{- end }}

{{/*
The prefix of the PrimeNet computer names (<prefix>-<pod number>). PrimeNet names are at most 20
characters (see mprime.maxComputerNameLength), and mprime replaces anything but letters, digits, '.', '-' and '_' with '_', so refuse
names that would not survive intact rather than let two pods end up with the same truncated name.
*/}}
{{- define "mprime.computerIdPrefix" -}}
{{- $prefix := .Values.config.computerIdPrefix -}}
{{- if not $prefix -}}
{{- $prefix = .Release.Name -}}
{{- with .Values.config.clusterName }}{{- $prefix = printf "%s-%s" $prefix . -}}{{- end -}}
{{- end -}}
{{- $longest := printf "%s-%d" $prefix (sub (int .Values.replicaCount) 1 | max 0) -}}
{{- $max := include "mprime.maxComputerNameLength" . | int -}}
{{- if gt (len $longest) $max -}}
{{- fail (printf "Computer name %q is %d characters; PrimeNet allows %d. Set config.computerIdPrefix to something shorter." $longest (len $longest) $max) -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" $prefix) -}}
{{- fail (printf "config.computerIdPrefix %q may only contain letters, digits, '.', '-' and '_'." $prefix) -}}
{{- end -}}
{{- $prefix -}}
{{- end }}

{{/*
Everything in the ConfigMap. Also hashed into the pod template, so the pods restart when it changes (and not for
chart-only changes such as a new chart version). toYaml quotes whatever is needed.
*/}}
{{- define "mprime.configData" -}}
{{- $d := dict "lib.sh" (.Files.Get "files/lib.sh") "init.sh" (.Files.Get "files/init.sh") "start.sh" (.Files.Get "files/start.sh") "managed.tsv" (include "mprime.managed" .) -}}
{{- if eq .Values.mode "job" }}
{{- $_ := set $d "job-worktodo.txt" (required "job.worktodo is needed in job mode: --set-file job.worktodo=worktodo.txt" .Values.job.worktodo) -}}
{{- end }}
{{- $d | toYaml -}}
{{- end }}

{{/* Job mode: the label that ties a job, its pods and its volume to a slot. */}}
{{- define "mprime.slotLabel" -}}mprime.primesearch.org/slot{{- end }}

{{/*
Job mode: the slot is what a job keeps between runs: the PrimeNet computer (name and GUID) and the volume.
It defaults to the release name, which is a new computer each time; name a slot to reuse one.
*/}}
{{- define "mprime.jobSlot" -}}
{{- $slot := default .Release.Name .Values.job.slot -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $slot) -}}
{{- fail (printf "job slot %q must be lower case letters, digits and '-', starting and ending with a letter or digit (set job.slot)." $slot) -}}
{{- end -}}
{{- $slot -}}
{{- end }}

{{/* Job mode: the volume of the slot, shared by every job that uses the slot. */}}
{{- define "mprime.jobClaimName" -}}
{{- $name := printf "%s-%s" .Values.job.computerPrefix (include "mprime.jobSlot" .) -}}
{{- if gt (len $name) 63 -}}
{{- fail (printf "volume name %q is longer than 63 characters; set a shorter job.slot." $name) -}}
{{- end -}}
{{- $name -}}
{{- end }}

{{/* Job mode: the PrimeNet computer name <prefix>[-<cluster>]-<slot>, or job.computerName as it is. */}}
{{- define "mprime.jobComputerName" -}}
{{- $name := .Values.job.computerName -}}
{{- if not $name -}}
{{- $name = .Values.job.computerPrefix -}}
{{- with .Values.config.clusterName }}{{- $name = printf "%s-%s" $name . -}}{{- end -}}
{{- $name = printf "%s-%s" $name (include "mprime.jobSlot" .) -}}
{{- end -}}
{{- $max := include "mprime.maxComputerNameLength" . | int -}}
{{- if gt (len $name) $max -}}
{{- fail (printf "Computer name %q is %d characters; PrimeNet allows %d. Set a shorter job.slot (or job.computerName)." $name (len $name) $max) -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" $name) -}}
{{- fail (printf "Computer name %q may only contain letters, digits, '.', '-' and '_'." $name) -}}
{{- end -}}
{{- $name -}}
{{- end }}

{{/* Job mode: refuse a slot that another release's job is running in (the volume is ReadWriteOnce, and two
     processes must not be one PrimeNet computer). Only works against a real cluster; helm template skips it. */}}
{{- define "mprime.checkSlotFree" -}}
{{- $slot := include "mprime.jobSlot" . -}}
{{- range $job := (lookup "batch/v1" "Job" .Release.Namespace "").items }}
{{- if and (eq (dig "metadata" "labels" (include "mprime.slotLabel" $) "" $job) $slot) (ne (dig "metadata" "labels" "app.kubernetes.io/instance" "" $job) $.Release.Name) (gt (int (dig "status" "active" 0 $job)) 0) }}
{{- fail (printf "slot %q is in use by release %q (job %s). Wait for it to finish, or choose another job.slot." $slot (dig "metadata" "labels" "app.kubernetes.io/instance" "" $job) $job.metadata.name) }}
{{- end }}
{{- end }}
{{- end }}
