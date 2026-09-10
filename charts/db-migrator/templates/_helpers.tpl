{{/* vim: set filetype=mustache: */}}

{{- define "db-migrator.fullname" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Vault static-creds ref for a tenant's DDL role, e.g.
     vault:strada-db/static-creds/business-time-db#username */}}
{{- define "db-migrator.credRef" -}}
{{- $t := .tenant -}}{{- $v := .ctx.Values.vault -}}{{- $key := .key -}}
{{- printf "vault:%s/static-creds/%s-%s#%s" $v.dbMount $t $v.roleSuffix $key -}}
{{- end -}}
