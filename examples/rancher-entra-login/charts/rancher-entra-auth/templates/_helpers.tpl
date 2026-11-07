{{/* The pod of the rotation job. The CronJob and the install job share it. */}}
{{- define "rancher-entra-auth.pod" -}}
metadata:
  labels:
    app.kubernetes.io/name: rancher-entra-auth
    app.kubernetes.io/instance: {{ .Release.Name }}
    # The workload identity webhook adds the Entra ID token file.
    azure.workload.identity/use: "true"
  annotations:
    checksum/script: {{ .Files.Get "files/rotate.sh" | sha256sum }}
    checksum/chart: {{ .Values.chartChecksum | quote }}
spec:
  serviceAccountName: {{ .Values.serviceAccountName }}
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: rotate
      image: {{ .Values.image }}
      command: ["/bin/sh", "/scripts/rotate.sh"]
      env:
        - name: HOME
          value: /work
        - name: WORK_DIR
          value: /work
        - name: RANCHER_CLIENT_ID
          value: {{ required "rancherClientId is required" .Values.rancherClientId | quote }}
        - name: RANCHER_URL
          value: {{ required "rancherUrl is required" .Values.rancherUrl | quote }}
        - name: ALLOWED_PRINCIPALS
          value: {{ concat .Values.adminPrincipals .Values.userPrincipals | toJson | quote }}
        - name: LIFETIME_DAYS
          value: {{ .Values.secret.lifetimeDays | quote }}
        - name: RENEW_BEFORE_DAYS
          value: {{ .Values.secret.renewBeforeDays | quote }}
        - name: SECRET_DISPLAY_NAME
          value: {{ .Values.secret.displayName | quote }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      volumeMounts:
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: work
          mountPath: /work
  volumes:
    - name: scripts
      configMap:
        name: {{ .Release.Name }}-script
        defaultMode: 0555
    # Memory-backed, so a secret never touches the disk of the node.
    - name: work
      emptyDir:
        medium: Memory
        sizeLimit: 16Mi
{{- end -}}
