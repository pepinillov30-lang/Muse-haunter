#!/usr/bin/env bash
# caza-a1-actions.sh — UN ciclo de caza para GitHub Actions.
# El schedule del workflow ES el bucle: este script intenta los 3 ADs una vez y termina.
# Adaptado de caza-a1.sh (versión PC/Hermes): 1 OCPU / 6 GB, VM.Standard.A1.Flex.
set -uo pipefail

# ============ Configuración (viene de GitHub Secrets) ============
# NOTA: sin COORD_URL/COORD_TOKEN a propósito — ningún proceso de fondo
# publica en el bus de coordinación (regla dura). La evidencia vive en los
# logs de Actions y, si cae la VM, en un Issue del repo + CAZADA.json.
COMPARTMENT_OCID="${OCI_COMPARTMENT_OCID:?falta OCI_COMPARTMENT_OCID}"
SUBNET_OCID="${OCI_SUBNET_OCID:?falta OCI_SUBNET_OCID}"
IMAGE_OCID="${OCI_IMAGE_OCID:?falta OCI_IMAGE_OCID}"
# ===================================================================

INSTANCE_NAME="claudia-os"
OCPUS=1
MEMORY_GB=6
BOOT_VOLUME_GB=50
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-$GITHUB_WORKSPACE/ssh/id_rsa_oracle.pub}"

LOG="$GITHUB_WORKSPACE/caza-a1.log"
log() { echo "[$(date -u '+%F %T')] $*" | tee -a "$LOG"; }

command -v oci >/dev/null || { log "ERROR: OCI CLI no instalado"; exit 1; }
command -v jq  >/dev/null || { log "ERROR: jq no instalado"; exit 1; }
command -v curl >/dev/null || { log "ERROR: curl no instalado"; exit 1; }
[ -f "$SSH_PUBKEY_FILE" ] || { log "ERROR: no existe $SSH_PUBKEY_FILE"; exit 1; }

# Idempotencia: si la VM ya existe, no hacer nada (el run es un no-op)
EXISTING=$(oci compute instance list --compartment-id "$COMPARTMENT_OCID" \
  --display-name "$INSTANCE_NAME" \
  --query 'data[?contains(`lifecycle-state`,`RUNNING`) || contains(`lifecycle-state`,`PROVISIONING`)].id' \
  --raw-output 2>/dev/null | jq -r '.[0] // empty')
if [ -n "$EXISTING" ]; then
  log "La VM $INSTANCE_NAME ya existe ($EXISTING). Nada que cazar en este ciclo."
  exit 0
fi

ADS=$(oci iam availability-domain list --compartment-id "$COMPARTMENT_OCID" \
  --query 'data[].name' --raw-output 2>/dev/null | jq -r '.[]')
[ -z "$ADS" ] && { log "ERROR: no se leen los AD (¿credenciales OCI válidas?)"; exit 1; }

log "Ciclo #${GITHUB_RUN_NUMBER:-?} — ADs: $(echo "$ADS" | tr '\n' ' ')— objetivo: $INSTANCE_NAME ${OCPUS} OCPU / ${MEMORY_GB} GB"

for ad in $ADS; do
  log "Intento en $ad..."
  OUT=$(oci compute instance launch \
    --compartment-id "$COMPARTMENT_OCID" \
    --availability-domain "$ad" \
    --shape VM.Standard.A1.Flex \
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
    --image-id "$IMAGE_OCID" \
    --subnet-id "$SUBNET_OCID" \
    --assign-public-ip true \
    --display-name "$INSTANCE_NAME" \
    --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
    --ssh-authorized-keys-file "$SSH_PUBKEY_FILE" \
    --wait-for-state RUNNING \
    --max-wait-seconds 100 2>&1)

  if echo "$OUT" | grep -qi "Out of host capacity\|out-of-host-capacity\|HostCapacity"; then
    log "  → sin capacidad en $ad"
    continue
  fi

  if echo "$OUT" | grep -q '"lifecycle-state": *"RUNNING"'; then
    IP=$(echo "$OUT" | grep -o '"public-ip": *"[^"]*"' | head -1 | cut -d'"' -f4)
    OCID=$(echo "$OUT" | grep -o '"id": *"ocid1.instance[^"]*"' | head -1 | cut -d'"' -f4)
    log "=== ¡CONSEGUIDA! RUNNING en $ad — IP: ${IP:-ver consola} ==="
    # Evidencia para el workflow: escribe CAZADA.json en el workspace.
    # El workflow abre un Issue con estos datos (señal visible, sin bus).
    jq -n --arg ip "${IP:-?}" --arg ad "$ad" --arg ocid "${OCID:-?}" \
      --arg ts "$(date -u '+%FT%TZ')" \
      '{cazada:true, ip:$ip, availability_domain:$ad, ocid:$ocid,
        shape:"VM.Standard.A1.Flex", ocpus:1, memory_gb:6,
        display_name:"claudia-os", utc:$ts}' > "$GITHUB_WORKSPACE/CAZADA.json"
    log "Evidencia escrita en CAZADA.json"
    exit 0
  fi

  log "  → otro error. Primeras líneas:"
  echo "$OUT" | head -5 | tee -a "$LOG"
  if echo "$OUT" | grep -qi "LimitExceeded"; then
    log "DEFINITIVO: LimitExceeded (¿ya existe otra A1 en el tenancy?). Revisar consola."
    exit 2
  fi
  if echo "$OUT" | grep -qi "NotAuthorized\|401\|Unauthorized\|InvalidParameter"; then
    log "DEFINITIVO: auth o parámetro inválido. Revisar Secrets y relanzar manual."
    exit 2
  fi
done

log "Ciclo sin hueco. El schedule lanza el siguiente en ~5 min."
