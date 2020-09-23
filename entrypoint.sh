#!/bin/bash
LAMBDA_URL="https://${INPUT_LAMBDA_REGION}.console.aws.amazon.com/lambda/home?region=${INPUT_LAMBDA_REGION}#/functions/"

# Taken from https://stackoverflow.com/a/21189044
parse_yaml(){
   local prefix=$2
   local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
   sed -ne "s|^\($s\):|\1|" \
        -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
   awk -F$fs '{
      indent = length($1)/2;
      vname[indent] = $2;
      for (i in vname) {if (i > indent) {delete vname[i]}}
      if (length($3) > 0) {
         vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
         printf("%s%s%s=%s\n", "'$prefix'",vn, $2, $3);
      }
   }'
}

# Taken from https://stackoverflow.com/a/17841619
function join_by { local IFS="$1"; shift; echo "$*"; }

does_lambda_exist() {
  aws lambda get-function --function-name $1 > /dev/null 2>&1
  if [ 0 -eq $? ]; then
    true
  else
    false
  fi
}

install_zip_dependencies(){
    echo "${LAMBDA_FUNCTION_NAME} Installing and zipping dependencies..."
    mkdir python
    pipenv lock --requirements >> requirements.txt
    pip install --target=python -qr requirements.txt
    if [[ $settings_exclude_botocore == "Y" || $settings_exclude_botocore == "y" || $settings_exclude_botocore == "yes" || $settings_exclude_botocore == "Yes" ]]
    then
        rm -rf ./python/botocore*
    fi
    zip -qr dependencies.zip ./python
    zipsplit -n 50000000 dependencies.zip
    rm dependencies.zip
    rm requirements.txt
    rm -rf python
}

process_dependencies() {
    echo "${LAMBDA_FUNCTION_NAME} process_dependencies..."
    ALL_LAMBDA_LAYERS=""
    FILES=depende*.zip
    for f in $FILES
    do
        publish_dependencies_as_layer $f
    done
    rm -rf python

}

publish_dependencies_as_layer(){
    echo "${LAMBDA_FUNCTION_NAME} publish_dependencies_as_layer..."
    echo ""
    FILE_NAME=$1
    echo "Publishing $FILE_NAME as a layer..."
    FILE_NUMBER=${FILE_NAME//[^0-9]/}
    echo "FILE_NUMBER: $FILE_NUMBER"
    LAYER_NAME="${LAMBDA_FUNCTION_NAME}-${FILE_NUMBER}"
    echo "LAYER_NAME: $LAYER_NAME"
    local result=$(aws lambda publish-layer-version --layer-name "${LAYER_NAME}" --zip-file fileb://${FILE_NAME})
    LAYER_VERSION_ARN=$(jq -r '.LayerVersionArn' <<< "$result")
    ALL_LAMBDA_LAYERS+=" ${LAYER_VERSION_ARN}"
    echo $ALL_LAMBDA_LAYERS
    rm ${FILE_NAME}
}

create_or_update_function_code(){
    echo "${LAMBDA_FUNCTION_NAME} Creating/Deploying the code itself..."

    does_lambda_exist $LAMBDA_FUNCTION_NAME
    status=$?
    if ! $(exit $status);
    then
        echo "Creating $LAMBDA_FUNCTION_NAME"
        aws lambda create-function --function-name $LAMBDA_FUNCTION_NAME --runtime $settings_runtime --role $settings_role --handler $settings_handler --zip-file fileb://code.zip
    else
        echo "Updating $LAMBDA_FUNCTION_NAME"
        aws lambda update-function-code --function-name "${LAMBDA_FUNCTION_NAME}" --zip-file fileb://code.zip
    fi
}

update_lambda_configuration() {
    ENV_VARS_VAL="Variables={$(join_by , ${settings_env_vars[@]})}"
    
    aws lambda update-function-configuration --function-name $LAMBDA_FUNCTION_NAME \
        --layers ${ALL_LAMBDA_LAYERS} \
        --runtime $settings_runtime \
        --role $settings_role \
        --handler $settings_handler \
        --timeout $settings_timeout \
        --memory-size $settings_memory \
        --vpc-config $settings_vpc_config \
        --file-system-configs $settings_fs_config \
        --environment $ENV_VARS_VAL
}

configure_aws_credentials(){
    aws configure set aws_access_key_id "${INPUT_AWS_ACCESS_KEY_ID}"
    aws configure set aws_secret_access_key "${INPUT_AWS_SECRET_ACCESS_KEY}"
    aws configure set default.region "${INPUT_LAMBDA_REGION}"
}

generate_function_name(){
    LAMBDA_FUNCTION_NAME="${INPUT_LAMBDA_FUNCTION_PREFIX}"
    if [ ! -z "$INPUT_LAMBDA_FUNCTION_SUFFIX" ]
    then
        LAMBDA_FUNCTION_NAME+="-${INPUT_LAMBDA_FUNCTION_SUFFIX}"
    fi
    LAMBDA_FUNCTION_NAME+="--$1"
}

process_lambda_config(){
    # check if config file actually exists
    if [ -f "$1config.yml" ]; then
        echo ""
        echo "Parsing $1config.yml"

        # parse config file with settings_ prefix
        eval $(parse_yaml $1config.yml settings_)

        generate_function_name $settings_name
        echo "Function: ${LAMBDA_FUNCTION_NAME}"

        # parse env vars
        settings_env_vars=()
        for var in "${!settings_env_vars_@}"; do
            settings_env_vars+=("${var#"settings_env_vars_"}=${!var}")
        done

        # add to our output variable
        OUTPUT_FUNCTIONS+=" - ${LAMBDA_URL}${LAMBDA_FUNCTION_NAME}%0A"
        
        # temporarily change working dir
        pushd $1

        # generate requirements.txt from Pipfile
        # pip install to ./python dir
        # zip dependencies
        # split into 50mb archives
        install_zip_dependencies

        # loop through all split archives
        # and push as layers
        process_dependencies

        zip_code

        # create or update function code
        create_or_update_function_code

        # update lambda config with new layers and settings from config.yml
        update_lambda_configuration
        
        clean_up

        # reset working directory
        popd
    fi
}

process_function_configs(){
    FUNCTION_DIRS=${INPUT_LAMBDA_CONFIGS_PATH}*/
    for f in $FUNCTION_DIRS
    do
        process_lambda_config $f
    done
}

zip_code(){
    if [ -z "${INPUT_LAMBDA_IGNORE_FILE}" ]
    then
        zip -r code.zip . -x \*.*/\*
    else
        zip -r code.zip . -x@${INPUT_LAMBDA_IGNORE_FILE}
    fi
}

clean_up(){
    rm code.zip
}

deploy_lambda_function(){
    OUTPUT_FUNCTIONS=""
    configure_aws_credentials
    process_function_configs
    echo $OUTPUT_FUNCTIONS
    echo "::set-output name=all_functions::$OUTPUT_FUNCTIONS"
}

deploy_lambda_function
echo "Each step completed, check the logs if any error occured."
