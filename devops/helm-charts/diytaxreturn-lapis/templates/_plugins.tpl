{{/*
Plugin overlays: plugins that ship as their own image (e.g. from a private repo) instead of being
baked into bwalia/opsapi. Each overlay image must contain the plugin at /plugin/<name>/ (project.lua,
api/, migrations/, ...). An init container copies it into an emptyDir mounted at /app/projects/<name>,
so the platform image stays unchanged and Ring Promoter keeps deploying it as usual. Used by both the
app pods and the migrate job (plugin migrations run in `lapis migrate`).

values:
  pluginOverlays:
    - name: portfoliolab                     # folder under /app/projects (and under /plugin in the image)
      image: registry.example/team/portfoliolab-plugin:1.2.3
      pullPolicy: Always                     # optional, default IfNotPresent
  imagePullSecrets:
    - name: my-registry-login
*/}}
{{- define "opsapi.pluginOverlays.initContainers" -}}
{{- range .Values.pluginOverlays }}
- name: plugin-{{ .name | replace "_" "-" }}
  image: {{ .image | quote }}
  imagePullPolicy: {{ .pullPolicy | default "IfNotPresent" }}
  command: ["sh", "-c", "cp -R /plugin/{{ .name }}/. /overlay/ && ls /overlay/project.lua"]
  volumeMounts:
    - name: plugin-{{ .name | replace "_" "-" }}
      mountPath: /overlay
  resources:
    requests: { cpu: 10m, memory: 16Mi }
    limits: { memory: 64Mi }
{{- end }}
{{- end }}

{{- define "opsapi.pluginOverlays.volumeMounts" -}}
{{- range .Values.pluginOverlays }}
- name: plugin-{{ .name | replace "_" "-" }}
  mountPath: /app/projects/{{ .name }}
  readOnly: true
{{- end }}
{{- end }}

{{- define "opsapi.pluginOverlays.volumes" -}}
{{- range .Values.pluginOverlays }}
- name: plugin-{{ .name | replace "_" "-" }}
  emptyDir: { sizeLimit: 64Mi }
{{- end }}
{{- end }}
