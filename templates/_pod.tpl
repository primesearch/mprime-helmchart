{{/*
The pod template (metadata and spec), shared by the StatefulSet (mode: statefulset) and the Job (mode: job).
The differences between the modes are all marked with $isJob.
*/}}
{{- define "mprime.podTemplate" -}}
{{- $isJob := eq .Values.mode "job" -}}
metadata:
  annotations:
    # Restart the pods when the generated configuration changes.
    checksum/config: {{ include "mprime.configData" . | sha256sum }}
    {{- with .Values.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  labels:
    {{- include "mprime.selectorLabels" . | nindent 4 }}
    {{- if $isJob }}
    {{ include "mprime.slotLabel" . }}: {{ include "mprime.jobSlot" . | quote }}
    {{- end }}
    {{- with .Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if $isJob }}
  # A new pod (not a restarted container) takes over after a failure or a pre-emption, on the same volume.
  restartPolicy: Never
  {{- end }}
  automountServiceAccountToken: false
  enableServiceLinks: false
  terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
  {{- with .Values.priorityClassName }}
  priorityClassName: {{ . }}
  {{- end }}
  securityContext:
    {{- toYaml .Values.podSecurityContext | nindent 4 }}
  initContainers:
    - name: config
      image: {{ include "mprime.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      command: ["/bin/bash", "{{ include "mprime.scriptsDir" . }}/init.sh"]
      env:
        - name: MPRIME_DIR
          value: {{ include "mprime.dataDir" . | quote }}
        - name: SCRIPTS
          value: {{ include "mprime.scriptsDir" . | quote }}
        - name: JOB_MODE
          value: {{ ternary "1" "0" $isJob | quote }}
        - name: USE_PRIMENET
          value: {{ ternary "1" "0" .Values.config.usePrimenet | quote }}
        {{- if $isJob }}
        - name: COMPUTER_ID
          value: {{ include "mprime.jobComputerName" . | quote }}
        # Identifies this Job, so its assignments are added to the worktodo once, not again after a restart.
        - name: JOB_UID
          valueFrom:
            fieldRef:
              fieldPath: metadata.labels['batch.kubernetes.io/controller-uid']
        {{- else if .Values.config.usePrimenet }}
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: COMPUTER_ID_PREFIX
          value: {{ include "mprime.computerIdPrefix" . | quote }}
        {{- end }}
      securityContext:
        {{- toYaml .Values.securityContext | nindent 8 }}
      # The same resources as mprime's container: a pod is only Guaranteed QoS (and only gets exclusive CPUs
      # from the static CPU manager) if every container, init containers included, has requests equal to limits.
      {{- with .Values.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      volumeMounts:
        - name: data
          mountPath: {{ include "mprime.dataDir" . }}
        - name: scripts
          mountPath: {{ include "mprime.scriptsDir" . }}
          readOnly: true
  containers:
    - name: mprime
      image: {{ include "mprime.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      # start.sh works out the thread count and memory, then runs: mprime -d -w<data dir>
      command: ["/bin/bash", "{{ include "mprime.scriptsDir" . }}/start.sh"]
      env:
        - name: MPRIME_DIR
          value: {{ include "mprime.dataDir" . | quote }}
        - name: SCRIPTS
          value: {{ include "mprime.scriptsDir" . | quote }}
        - name: JOB_MODE
          value: {{ ternary "1" "0" $isJob | quote }}
        - name: JOB_MAX_WAIT_SECONDS
          value: {{ .Values.job.maxWaitSeconds | int | quote }}
        - name: CORES_PER_TEST
          value: {{ .Values.config.coresPerTest | int | quote }}
        # The CPU limit of this container, rounded up to whole CPUs (the node's CPUs if there is none).
        - name: CPU_LIMIT_CORES
          valueFrom:
            resourceFieldRef:
              resource: limits.cpu
              divisor: "1"
        - name: MEMORY_MB
          value: {{ .Values.config.memoryMB | int | quote }}
        - name: MEMORY_RESERVE_MB
          value: {{ .Values.config.memoryReserveMB | int | quote }}
        - name: MEMORY_RESERVE_PERCENT
          value: {{ .Values.config.memoryReservePercent | int | quote }}
        - name: MEMORY_MIN_MB
          value: {{ .Values.config.memoryMinMB | int | quote }}
        # The memory limit of this container (in MiB), or the node's allocatable memory if there is none.
        - name: MEMORY_LIMIT_SET
          value: {{ if (default dict (default dict .Values.resources).limits).memory }}"1"{{ else }}"0"{{ end }}
        - name: MEMORY_LIMIT_MB
          valueFrom:
            resourceFieldRef:
              resource: limits.memory
              divisor: 1Mi
      securityContext:
        {{- toYaml .Values.securityContext | nindent 8 }}
      {{- with .Values.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      volumeMounts:
        - name: data
          mountPath: {{ include "mprime.dataDir" . }}
        - name: scripts
          mountPath: {{ include "mprime.scriptsDir" . }}
          readOnly: true
  volumes:
    - name: scripts
      configMap:
        name: {{ include "mprime.fullname" . }}
    {{- if $isJob }}
    - name: data
      {{- if .Values.persistence.enabled }}
      persistentVolumeClaim:
        claimName: {{ include "mprime.jobClaimName" . }}
      {{- else }}
      emptyDir: {}
      {{- end }}
    {{- else if not .Values.persistence.enabled }}
    - name: data
      emptyDir: {}
    {{- end }}
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if .Values.affinity }}
  affinity:
    {{- toYaml .Values.affinity | nindent 4 }}
  {{- else if and .Values.spreadAcrossNodes (not $isJob) }}
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            topologyKey: kubernetes.io/hostname
            labelSelector:
              matchLabels:
                {{- include "mprime.selectorLabels" . | nindent 16 }}
  {{- end }}
{{- end }}
