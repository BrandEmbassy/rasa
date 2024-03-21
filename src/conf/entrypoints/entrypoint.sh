#!/bin/bash
trap "exit 0" SIGTERM

RASA_OPTIONS=''

## create new file descriptor and use it for logging of this script
if [ "${ENTRYPOINT_LOG}" == "INFO" ]; then
    exec 3>&1
else
    exec 3>/dev/null
fi

RASA_DEBUG=${RASA_DEBUG,,}
if [[ " y yes t true 1 " =~ " ${RASA_DEBUG} " ]]; then
  RASA_OPTIONS="${RASA_OPTIONS} -vv"
fi

log () {
  echo >&3 "entrypoint: $1"
}

update_training_state () {
  state="$1"
  error="$2"
  model_id="$3"

  if [ -n "${error}" ]; then
    error='"'$(echo ${error} | sed -e 's|[\]|\\\\|g' -e 's/"/\\"/g')'"'
  else
    error="null"
  fi

  if [ -n "${model_id}" ]; then
    model_id='"'${model_id}'"'
  else
    model_id="null"
  fi

  if [ -n ${RMA_URL} ]; then
    curl -s -X PUT ${RMA_URL}/bot/${EXTERNAL_BOT_ID}/training/${RMA_TRAINING_ID} \
      -H 'content-type: application/json' \
      -d '{"state": "'"${state}"'", "error": '"${error}"', "model_id": '"${model_id}"'}'
    [ $? -ne 0 ] && log "Failed to update Training status on ${RMA_URL} endpoint"
  fi
}

create_model () {
  s3_bucket=$1
  s3_object=$2

  if [ -n ${RMA_URL} ]; then
    model=$(curl -s -X POST ${RMA_URL}/bot/${EXTERNAL_BOT_ID}/model \
      -H 'content-type: application/json' \
      -d '{"s3_bucket": "'"${s3_bucket}"'", "s3_object": "'"${s3_object}"'"}')
    [ $? -ne 0 ] && log "Failed to create Model on ${RMA_URL} endpoint"

    echo "${model}" | jq -r '.id'
  fi
}

## run RASA container if AWS ENV variables are set
if [ -z "${AWS_DEFAULT_REGION}" ] || [ -z "${BUCKET_NAME}" ]; then
  log "Missing AWS configuration!"
  log "  \$AWS_DEFAULT_REGION: ${AWS_DEFAULT_REGION}"
  log "  \$BUCKET_NAME: ${BUCKET_NAME}"
  exit 1
fi

case $1 in
  train)
    if [ -z "${RASA_TRAINING_CONFIG_S3_OBJECT}" ] || [ -z "${RASA_MODEL_S3_OBJECT}" ]; then
      log "Missing RASA configuration!"
      log "  \$RASA_TRAINING_CONFIG_S3_OBJECT: ${RASA_TRAINING_CONFIG_S3_OBJECT}"
      log "  \$RASA_MODEL_S3_OBJECT: ${RASA_MODEL_S3_OBJECT}"
      exit 1
    fi

    update_training_state "processing"

    aws s3 cp s3://${BUCKET_NAME}/$2/training/${RASA_TRAINING_CONFIG_S3_OBJECT} /app/training/
    if [ $? -ne 0 ]; then
      log "Failed to download training configuration for ${EXTERNAL_BOT_ID}::${RMA_TRAINING_ID} from ${BUCKET_NAME}/$2/training/${RASA_TRAINING_CONFIG_S3_OBJECT}"
      update_training_state "error" "Failed to download training configuration for ${EXTERNAL_BOT_ID}::${RMA_TRAINING_ID} from ${BUCKET_NAME}/$2/training/${RASA_TRAINING_CONFIG_S3_OBJECT}"
      exit 1
    fi

    /opt/venv/bin/rasa run --enable-api -p 5000 --response-timeout 36000 ${RASA_OPTIONS} &

    log "Waiting for local RASA endpoint for ${EXTERNAL_BOT_ID}::${RMA_TRAINING_ID}"
    while true; do
      curl -s -X GET http://localhost:5000
      [ $? -eq 0 ] && break
      sleep 1
    done

    log "Invoking training on local RASA endpoint for ${EXTERNAL_BOT_ID}::${RMA_TRAINING_ID}"
    curl -s -XPOST http://localhost:5000/model/train -H 'Content-type: application/x-yaml' --data-binary @/app/training/${RASA_TRAINING_CONFIG_S3_OBJECT} -o /app/training/curl_training.out
    if [ $? -ne 0 ]; then
      log "Failed to call RASA endpoint /model/train on http://localhost:5000 for ${EXTERNAL_BOT_ID}::${RMA_TRAINING_ID}"
      update_training_state "error" '{"message":"Failed to invoke training"}'
      exit 1
    fi

    if jq -e . /app/training/curl_training.out >/dev/null 2>&1; then
      log "Training crashed for ${EXTERNAL_BOT_ID}::${RMA_TRAINING_ID}"
      update_training_state "error" "$(< /app/training/curl_training.out)"
      exit 1
    else
      log "Uploading model for ${EXTERNAL_BOT_ID}::${RMA_TRAINING_ID}"
      aws s3 cp /app/training/curl_training.out "s3://${BUCKET_NAME}/$2/models/${RASA_MODEL_S3_OBJECT}.tar.gz"
      if [ $? -ne 0 ]; then
        log "Failed to upload new model for ${EXTERNAL_BOT_ID}::${RMA_TRAINING_ID} to ${BUCKET_NAME}/$2/models"
        update_training_state "error" '{"message":"Failed to save new model"}'
        exit 1
      fi
      model_id=$(create_model "${BUCKET_NAME}" "${EXTERNAL_BOT_ID}/models/${RASA_MODEL_S3_OBJECT}.tar.gz")
      update_training_state "done" "" "${model_id}"
    fi

    ;;
  run)
    ## create RASA configuration files based on ENV variables
    log "Processing configuration templates"

    ## substitute only what's available in env
    envvars=$(env | grep 'RASA_.*\?=.\+' | awk -F= '{printf (NR>1?":":"")"${"$1"}";}')

    for config in credentials endpoints; do
      if [ -f "/app/${config}.template" ] && [ ! -f "/app/${config}.yml" ]; then
        log "Processing template /app/${config}.template"
        envsubst "${envvars}" < "/app/${config}.template" > "/app/${config}.yml"
        ## Remove undefined empty lines? / fallback to defaults?
        #sed -i '/: /!d' /app/${config}.yml
      else
        log "File ${config}.yml already exists or ${config}.template not found, skipping..."
      fi
    done

    if [ -z "${RASA_MODEL_S3_OBJECT}" ]; then
      log "WARNING: No model set, running RASA API with default model!"
      RASA_MODEL_S3_OBJECT='default_model/default.tar.gz'
    fi
    /opt/venv/bin/rasa run --model ${RASA_MODEL_S3_OBJECT} --remote-storage aws --enable-api -p 5000 --endpoints endpoints.yml --credentials credentials.yml ${RASA_OPTIONS}
    ;;
  bash)
    /bin/bash
    ;;
  *)
    echo "Wrong input. Expecting either 'train <external_bot_id>', 'run <port_number>', or 'bash'"
    exit 1
    ;;
esac
