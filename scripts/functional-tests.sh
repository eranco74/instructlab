#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -ex

# build a prompt string that includes the time, source file, line number, and function name
export PS4='+$(date +"%Y-%m-%d %T") ${BASH_VERSION}:${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

export TEST_DIR
export PACKAGE_NAME='instructlab'  # name we use of the top-level package directories for CLI data


# get the directories from the platformdirs library
export CONFIG_DIR
export DATA_DIR
export CACHE_DIR


# we define the path here to reference elsewhere, but the existence of this file
# will be managed by the ilab CLI
export ILAB_CONFIGDIR_LOCATION
export ILAB_CONFIG_FILE
export ILAB_DATA_DIR


########################################
# Initializes the environment necessary for this test script
# Creates a temporary directory structure for the test data,
# and sets the necessary environment variables.
# 
# Arguments:
#   None
# Globals:
#   HOME
#   ILAB_DATA_DIR
#   ILAB_CONFIG_FILE
#   ILAB_CONFIGDIR_LOCATION
#   CACHE_DIR
#   DATA_DIR
#   CONFIG_DIR
# Outputs:
#   Writes logs to stdout
########################################
function init_test_script() {
    local configdir_script
    local datadir_script
    local prev_home="${HOME}"

    printf 'initializing test script...\n'
    TEST_DIR=$(mktemp -d)
    HOME="${TEST_DIR}"  # to ensure platformdirs uses the test directory for the duration of this script
    printf 'changing home directory to "%s", was: "%s"\n' "${HOME}" "${prev_home}"

    # get the directories from the platformdirs library
    CONFIG_DIR=$(python -c "import platformdirs; print(platformdirs.user_config_dir())")
    DATA_DIR=$(python -c "import platformdirs; print(platformdirs.user_data_dir())")
    CACHE_DIR=$(python -c "import platformdirs; print(platformdirs.user_cache_dir())")

    configdir_script=$(printf 'import platformdirs; print(platformdirs.user_config_dir("%s"))' "${PACKAGE_NAME}")
    datadir_script=$(printf 'import platformdirs; print(platformdirs.user_data_dir("%s"))' "${PACKAGE_NAME}")

    ILAB_CONFIGDIR_LOCATION=$(python -c "${configdir_script}")
    ILAB_CONFIG_FILE="${ILAB_CONFIGDIR_LOCATION}/config.yaml"
    ILAB_DATA_DIR=$(python -c "${datadir_script}")

    # ensure these exist at the time of running the test
    for d in "${CONFIG_DIR}" "${DATA_DIR}" "${CACHE_DIR}"; do
        printf 'creating directory: "%s"\n' "${d}"
        mkdir -p "${d}"
    done
    printf 'finished initializing test script\n'
}


export TEST_CTX_SIZE_LAB_SERVE_LOG_FILE=test_ctx_size_lab_serve.log
export TEST_CTX_SIZE_LAB_CHAT_LOG_FILE=test_ctx_size_lab_chat.log

for cmd in ilab expect timeout; do
    if ! type -p $cmd; then
        echo "Error: ${cmd} is not installed"
        exit 1
    fi
done

PID_SERVE=
PID_CHAT=

chat_shot="ilab model chat -qq"

cleanup() {
    set +e
    if [ "${1:-0}" -ne 0 ]; then
        printf "\n\n"
        printf "\e[31m=%.0s\e[0m" {1..80}
        printf "\n\e[31mERROR OCCURRED\e[0m\n"
        printf "\e[31mFunction: %s\e[0m\n" "${FUNCNAME[1]}"
        printf "\e[31mExit Code: %s\e[0m\n" "$1"
        printf "\e[31m=%.0s\e[0m" {1..80}
        printf "\n\n"
    fi
    for pid in $PID_SERVE $PID_CHAT; do
        if [ -n "$pid" ]; then
            kill "$pid"
            wait "$pid"
        fi
    done
    rm -f "$TEST_CTX_SIZE_LAB_SERVE_LOG_FILE" \
        "$TEST_CTX_SIZE_LAB_CHAT_LOG_FILE" \
        test_session_history
    rm -rf test_taxonomy
    # revert port change from test_bind_port()
    sed -i.bak 's/9999/8000/g' "${ILAB_CONFIG_FILE}"

    # revert model name change from test_model_print()
    local original_model_name='merlinite-7b-lab-Q4_K_M'
    local original_model_filename="${original_model_name}.gguf"
    local temporary_model_filename='foo.gguf'
    sed -i.bak "s/baz/${original_model_name}/g" "${ILAB_CONFIG_FILE}"
    mv "${ILAB_DATA_DIR}/models/${temporary_model_filename}" "${ILAB_DATA_DIR}/models/${original_model_filename}" || true
    rm -f "${ILAB_CONFIG_FILE}.bak" serve.log "${ILAB_DATA_DIR}/models/${temporary_model_filename}"
    set -e
}

init_test_script
trap 'cleanup "${?}"; rm -rf "${TEST_DIR}"' EXIT QUIT INT TERM

rm -f "${ILAB_CONFIG_FILE}"

# print version
ilab --version

# print system information
ilab system info

# pipe 3 carriage returns to ilab config init to get past the prompts
echo -e "\n\n\n" | ilab init

# Enable Debug in func tests with debug level 1
sed -i.bak -e 's/log_level:.*/log_level: DEBUG/g;' "${ILAB_CONFIG_FILE}"
sed -i.bak -e 's/debug_level:.*/debug_level: 1/g;' "${ILAB_CONFIG_FILE}"

# It looks like GitHub action MacOS runner does not have graphics
# so we need to disable the GPU layers if we are running in GitHub actions
if [[ "$(uname)" == "Darwin" ]]; then
    if command -v system_profiler; then
        if system_profiler SPDisplaysDataType|grep "Metal Support"; then
            echo "Metal GPU detected"
        else
            echo "No Metal GPU detected"
            sed -i.bak -e 's/gpu_layers: -1/gpu_layers: 0/g;' "${ILAB_CONFIG_FILE}"
        fi
    else
        echo "system_profiler not found, cannot determine GPU"
    fi
fi

# download the latest version of the ilab
ilab model download

# check that ilab model serve is working
test_bind_port(){
    local formatted_script
    formatted_script=$(printf '
    set timeout 60
    spawn ilab model serve
    expect {
        "http://127.0.0.1:8000/docs" { puts OK }
        default { exit 1 }
    }

    # check that ilab model serve is detecting the port is already in use
    # catch "error while attempting to bind on address ...."
    spawn ilab model serve
    expect {
        "error while attempting to bind on address " { puts OK }
        default { exit 1 }
    }

    # configure a different port
    exec sed -i.bak 's/8000/9999/g' %s

    # check that ilab model serve is working on the new port
    # catch ERROR strings in the output
    spawn ilab model serve
    expect {
        "http://127.0.0.1:9999/docs" { puts OK }
        default { exit 1 }
    }
' "${ILAB_CONFIG_FILE}")
    expect -c "${formatted_script}"
}

test_ctx_size(){
    # A context size of 55 will allow a small message
    ilab model serve --max-ctx-size 25 &> "$TEST_CTX_SIZE_LAB_SERVE_LOG_FILE" &
    PID_SERVE=$!

    # Make sure the server has time to open the port
    # if "ilab model chat" tests it before its open then it will run its own server without --max-ctx-size 1
    wait_for_server

    # SHOULD SUCCEED: ilab model chat will trim the SYS_PROMPT then take the second message
    ${chat_shot} "Hello"

    # SHOULD FAIL: ilab model chat will trim the SYS_PROMPT AND the second message, then raise an error
    # The errors from failures will be written into the serve log and chat log files
    ${chat_shot} "hello, I am a ci message that should not finish because I am too long for the context window, tell me about your day please?
    How many tokens could you take today. Could you tell me about the time you could only take twenty five tokens" &> "$TEST_CTX_SIZE_LAB_CHAT_LOG_FILE" &
    PID_CHAT=$!

    # look for the context size error in the server logs
    if ! timeout 20 bash -c "
        until grep -q 'exceed context window of' $TEST_CTX_SIZE_LAB_SERVE_LOG_FILE; do
        echo 'waiting for context size error'
        sleep 1
    done
"; then
        echo "context size error not found in server logs"
        cat $TEST_CTX_SIZE_LAB_SERVE_LOG_FILE
        exit 1
    fi

    # look for the context size error in the chat logs
    if ! timeout 20 bash -c "
        until grep -q 'Message too large for context size.' $TEST_CTX_SIZE_LAB_CHAT_LOG_FILE; do
        echo 'waiting for chat error'
        sleep 1
    done
"; then
        echo "context size error not found in chat logs"
        cat $TEST_CTX_SIZE_LAB_CHAT_LOG_FILE
        exit 1
    fi
}

test_loading_session_history(){
    ilab model serve --backend llama-cpp --max-ctx-size 128 &
    PID_SERVE=$!

    # chat with the server
    expect -c '
        set timeout 120
        spawn ilab model chat
        expect ">>>"
        send "this is a test! what are you? do not exceed ten words in your reply.\r"
        send "/s test_session_history\r"
        send "exit\r"
        expect eof
    '

    # verify the session history file was created
    if ! timeout 5 bash -c "
        until test -s test_session_history; do
        echo 'waiting for session history file to be created'
        sleep 1
    done
"; then
        echo "session history file not found"
        exit 1
    fi

    expect -c '
        spawn ilab model chat -s test_session_history
        expect {
            "this is a test! what are you? do not exceed ten words in your reply." { exit 0 }
            timeout { exit 1 }
        }
        send "/l test_session_history\r"
        expect {
            "this is a test! what are you? do not exceed ten words in your reply." { exit 0 }
            timeout { exit 1 }
        }
    '
}

test_generate(){
    mkdir -p test_taxonomy/compositional_skills
    cat - <<EOF >  test_taxonomy/compositional_skills/simple_math.yaml
created_by: ci
version: 2
seed_examples:
  - question: what is 1+1
    answer: it is 2
  - question: what is 1+3
    answer: it is 4
  - question: what is 2+3
    answer: it is 5
  - question: what is 2+5
    answer: it is 7
  - question: what is 7+3
    answer: it is 10
task_description: "simple maths"
EOF

    sed -i.bak -e 's/num_instructions:.*/num_instructions: 1/g' "${ILAB_CONFIG_FILE}"

    # This should be finished in a minute or so but time it out incase it goes wrong
    if ! timeout 20m ilab data generate --taxonomy-path test_taxonomy/compositional_skills/simple_math.yaml; then
        echo "Error: ilab data generate command took more than 20 minutes and was cancelled"
        exit 1
    fi

    # Test if generated was created and contains files
    local generated_dir
    generated_dir="${ILAB_DATA_DIR}/datasets"
    ls -l "${generated_dir}/"*
    if [ "$(jq ". | length" < "$(find "${generated_dir}/generated_*" | tail -n 1)")" -lt 1 ] ; then
        echo "Not enough generated results"
        exit 1
    fi
}

test_model_train() {
    # TODO: call `ilab model train`
    if [[ "$(uname)" == Linux ]]; then
        # real `ilab model train` on Linux produces models/ggml-model-f16.gguf
        # fake gml-model-f16.gguf the same as merlinite-7b-lab-Q4_K_M.gguf
        test -f "${ILAB_DATA_DIR}/models/ggml-model-f16.gguf" || \
            ln -s merlinite-7b-lab-Q4_K_M.gguf "${ILAB_DATA_DIR}/models/ggml-model-f16.gguf"
    fi
}

test_model_test() {
    if [[ "$(uname)" == Linux ]]; then
        echo Using the latest of:
        ls -ltr "${ILAB_DATA_DIR}"/datasets/test_*
        timeout 20m ilab model test > model_test.out
        cat model_test.out
        grep -q '### what is 1+1' model_test.out
        grep -q 'merlinite-7b-lab-Q4_K_M.gguf: The sum of 1 and 1 is indeed 2' model_test.out
    fi
}

test_temp_server(){
    expect -c '
        set timeout 120
        spawn ilab model chat
        expect {
            "Trying to connect to model server at" { exit 0 }
            timeout { exit 1 }
        }
    '
}

test_temp_server_sigint(){
    expect -c '
        set timeout 120
        spawn ilab model chat
        expect "Trying to connect to model server at"
        send "hello!\r"
        sleep 5
        send "\003"
        expect "Disconnected from client (via refresh/close)"
        send "\003"
        send "hello again\r"
        sleep 1
        expect {
            "Connection error, try again" { exit 1 }
        }
    '
}

test_no_chat_logs(){
    expect -c '
        set timeout 120
        spawn ilab model chat
        expect "Trying to connect to model server at"
        send "hello!\r"
        sleep 1
        expect {
            "_base_client.py" { exit 1 }
        }
        '
}


test_temp_server_ignore_internal_messages(){
    # shellcheck disable=SC2016
    expect -c '
        set timeout 60
        spawn ilab model chat
        expect "Starting a temporary server at"
        send "hello!\r"
        sleep 5
        send "\003"
        expect {
            "Disconnected from client (via refresh/close)" { exit 1 }
        }
        send "exit\r"
        expect {
            "Traceback (most recent call last):" { set exp_result 1 }
            default { set exp_result 0 }
        }
        if { $exp_result != 0 } {
            puts stderr "Error: ilab model chat command failed"
            exit 1
        }
    '
}

test_server_welcome_message(){
    # test that the server welcome message is displayed
    ilab model serve --log-file serve.log &
    PID_SERVE=$!

    wait_for_server

    if ! timeout 10 bash -c '
        until test -s serve.log; do
        echo "waiting for server log file to be created"
        sleep 1
    done
    '; then
        echo "server log file was not created"
        exit 1
    fi
}

wait_for_server(){
    if ! timeout 60 bash -c '
        until curl 127.0.0.1:8000|grep "{\"message\":\"Hello from InstructLab! Visit us at https://instructlab.ai\"}"; do
            echo "waiting for server to start"
            sleep 1
        done
    '; then
        echo "server did not start"
        exit 1
    fi
}


########################################
# This function converts a given string to uppercase.
# Arguments:
#  A string to convert to uppercase.
# Outputs:
#  The uppercase string.
########################################
function to_upper() {
    local to_convert="$1"
    printf '%s' "${to_convert^^}"
}

test_model_print(){
    local src_model="${ILAB_DATA_DIR}/models/merlinite-7b-lab-Q4_K_M.gguf"
    local target_model="${ILAB_DATA_DIR}/models/foo.gguf"
    cp "${src_model}" "${target_model}"
    ilab model serve --model-path "${target_model}" &
    PID_SERVE=$!

    wait_for_server

    # validate that we print the model from the server since it is different from the config
    # shellcheck disable=SC2154,SC1001,SC2016
    local expected_model_name
    local expect_script
    expected_model_name=$(to_upper "${target_model}")
    # shellcheck disable=SC2016
    expect_script=$(printf '
        spawn ilab model chat
        expect {
            -re "Welcome to InstructLab Chat w/ \\\u001b\\\[1m%s" { exit 0 }
            eof { catch wait result; exit [lindex $result 3] }
            timeout { exit 1 }
        }
    ' "${expected_model_name}")
    expect -c "${expect_script}" 

    # validate that we fail on invalid model
    # shellcheck disable=SC2016
    expect_script=$(printf '
        set timeout 30
        spawn ilab model chat -m bar
        expect {
           "Executing chat failed with: Model bar is not served by the server. These are the served models: ['%s']" { exit 0 }
        }
    ' "${target_model}")
    expect -c "${expect_script}"

    # If we don't specify a model, validate that we print the model reported
    # by the server since it is different from the config.
    # shellcheck disable=SC2016
    expect_script=$(printf '
        spawn ilab model chat
        expect {
            -re "Welcome to InstructLab Chat w/ \\\u001b\\\[1m%s" { exit 0 }
            eof { catch wait result; exit [lindex $result 3] }
            timeout { exit 1 }
        }
    ' "${expected_model_name}")
    expect -c "${expect_script}"
}

########
# MAIN #
########
# call cleanup in-between each test so they can run without conflicting with the server/chat process
test_bind_port
cleanup
test_ctx_size
cleanup
test_loading_session_history
cleanup
test_generate
cleanup
test_model_train
cleanup
test_model_test
cleanup
test_temp_server
cleanup
test_temp_server_sigint
cleanup
test_no_chat_logs
cleanup
test_temp_server_ignore_internal_messages
cleanup
test_server_welcome_message
cleanup
test_model_print

exit 0
