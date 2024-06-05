#!/bin/bash

# 定义中间文件路径
TMP_DIR="/tmp/build_nanos_log"
mkdir -p "$TMP_DIR"
RESULT_LOG="$TMP_DIR/result.log"
UNIQUE_FILTERED_RESULT_LOG="$TMP_DIR/unique_filtered_result.log"
PKG_SO_FILES_LOG="$TMP_DIR/pkg_so_files.log"
FINAL_RESULT_LOG="$TMP_DIR/final_result.log"
LIB_TARGET_DIR="usr/lib"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 变量
PACKAGE=""
ENV_VARS=()

# 打印日志函数
log() {
    local level="$1"
    local message="$2"
    case "$level" in
        INFO) echo -e "${GREEN}[INFO]${NC} $message" ;;
        WARNING) echo -e "${YELLOW}[WARNING]${NC} $message" ;;
        ERROR) echo -e "${RED}[ERROR]${NC} $message" ;;
        *) echo -e "$message" ;;
    esac
}

# 打印使用方法
usage() {
    log "INFO" "usage  : $0 [-p <package>] [-e <env_var1=value1> -e <env_var2=value2> ...] program"
    log "INFO" "example: $0 -p eyberg/python_3.10.6 -e MY_VAR=123 -e ANOTHER_VAR=456 python main.py"
    exit 1
}

print_table() {
    local input="$1"
    local line_length=50
    local border
    printf -v border '+%.0s' {1..52}
    border="+${border}+"
    
    echo "$border"
    echo "$input" | while IFS= read -r line; do
        printf "| %-50s |\n" "$line"
    done
    echo "$border"
}

# 检查并安装必要的工具
install_tools() {
    install_tool() {
        local tool="$1"
        if ! command -v "$tool" &> /dev/null; then
            log "WARNING" "$tool not installed, trying to install..."
            case "$tool" in
                ops)
                    curl https://ops.city/get.sh -sSfL | sh
                    # 判断当前使用的Shell，并执行相应的source命令
                    case "$SHELL" in
                        */bash) source ~/.bashrc ;;
                        */zsh) source ~/.zshrc ;;
                        *)
                            log "WARNING" "Unsupported shell. Please manually source your shell configuration file."
                            ;;
                    esac
                    ;;
                strace)
                    if [ -f /etc/debian_version ]; then
                        sudo apt-get update && sudo apt-get install -y strace
                    elif [ -f /etc/centos-release ]; then
                        sudo yum install -y strace
                    elif [ -f /etc/arch-release ]; then
                        sudo pacman -Sy strace --noconfirm
                    else
                        log "ERROR" "Unsupported OS. Please install strace manually."
                        exit 1
                    fi
                    ;;
                jq)
                    if [ -f /etc/debian_version ]; then
                        sudo apt-get update && sudo apt-get install -y jq
                    elif [ -f /etc/centos-release ]; then
                        sudo yum install -y jq
                    elif [ -f /etc/arch-release ]; then
                        sudo pacman -Sy jq --noconfirm
                    else
                        log "ERROR" "Unsupported OS. Please install jq manually."
                        exit 1
                    fi
                    ;;
            esac
            if ! command -v "$tool" &> /dev/null; then
                log "ERROR" "$tool installation failed, please install it manually."
                exit 1
            fi
        fi
    }

    for tool in ops strace jq; do
        install_tool "$tool"
    done

    clear
}


# 运行 strace 并过滤结果
run_strace() {
    log "INFO" "Program running..."
    env "${ENV_VARS[@]}" strace -f -e trace=openat "${cmd[@]}" 2>&1 | grep '\.so' | grep -v '= -1' | grep -v 'ld.so.cache' | awk -F '"' '/\.so/ {print $2}' > "$RESULT_LOG"
}

# 处理 result.log 中的路径
process_result_log() {
    log "INFO" "Filtering, deduplication, and sorting..."
    declare -A file_map

    while read -r line; do
        abs_path=$(realpath -s "$line")
        if [[ ! "$abs_path" =~ site-packages ]] && [[ ! "$abs_path" =~ lib-dynload ]]; then
            filename=$(basename "$abs_path")
            if [[ -z ${file_map[$filename]} || $abs_path == /lib/* ]]; then
                file_map[$filename]=$abs_path
            fi
        fi
    done < "$RESULT_LOG"

    for path in "${file_map[@]}"; do
        echo "$path"
    done | sort > "$UNIQUE_FILTERED_RESULT_LOG"
}

# 检查包内容
check_package_contents() {
    if [ -n "$PACKAGE" ]; then
        log "INFO" "Check the contents of the package: $PACKAGE..."
        pkg_contents=$(ops pkg contents "$PACKAGE" 2>&1)

        if echo "$pkg_contents" | grep -q "package not found"; then
            log "ERROR" "Package $PACKAGE not found"
            exit 1
        else
            echo "$pkg_contents" | grep '\.so' | grep -v 'site-packages' | grep -v 'lib-dynload' | awk -F'File :' '{ if ($2) print $2 }' > "$PKG_SO_FILES_LOG"
        fi
    fi
}

# 过滤最终结果
filter_final_result() {
    if [ -f "$PKG_SO_FILES_LOG" ]; then
        log "INFO" "Final filtration..."
        declare -A pkg_file_map

        while read -r line; do
            filename=$(basename "$line")
            pkg_file_map[$filename]=1
        done < "$PKG_SO_FILES_LOG"

        while read -r line; do
            filename=$(basename "$line")
            if [[ -z ${pkg_file_map[$filename]} ]]; then
                echo "$line"
            fi
        done < "$UNIQUE_FILTERED_RESULT_LOG" > "$FINAL_RESULT_LOG"

        log "INFO" "The final result has been saved to $FINAL_RESULT_LOG"
    else
        mv "$UNIQUE_FILTERED_RESULT_LOG" "$FINAL_RESULT_LOG"
        log "INFO" "The final result has been saved to $FINAL_RESULT_LOG"
    fi
}

# 复制文件到目标目录
copy_files_to_target() {
    mkdir -p "$LIB_TARGET_DIR"

    log "INFO" "copy shared object to $LIB_TARGET_DIR..."
    while read -r line; do
        filename=$(basename "$line")
        source_path="$line"
        target_path="$LIB_TARGET_DIR/$filename"
        
        if [ -f "/lib/x86_64-linux-gnu/$filename" ]; then
            cp "/lib/x86_64-linux-gnu/$filename" "$target_path"
            log "INFO" "/lib/x86_64-linux-gnu/$filename -> $target_path"
        else
            cp "$source_path" "$target_path"
            log "INFO" "$source_path -> $target_path"
        fi
    done < "$FINAL_RESULT_LOG"
}

# 导入 JSON 生成函数
generate_config() {
    log "INFO" "Generating or updating config.json..."
    
    # 初始化 json_content
    json_content='{}'
    if [ -f config.json ]; then
        json_content=$(cat config.json)
    fi
    
    dirs='["usr"]'
    map_dirs='{}'
    map_dirs_empty=true
    files_empty=true

    # 获取 Args 数组
    args=("${cmd[@]:1}")

    # 获取 Files 数组
    files=()
    for arg in "${cmd[@]}"; do
        if [[ "$arg" == *.py || "$arg" == *.js ]]; then
            files+=("$arg")
        fi
    done

    # 检查是否为 Python 环境
    if [[ "$(basename "${cmd[0]}")" =~ ^python(3(\.[0-9]+)?)?$ ]]; then
        for hidden_dir in .??*; do
            if [ -d "$hidden_dir/bin" ] && [ -f "$hidden_dir/bin/python" ]; then
                if [ "$hidden_dir" == ".local" ]; then
                    dirs=$(echo "$dirs" | jq '. + ["'"$hidden_dir"'"]')
                else
                    map_dirs=$(echo "$map_dirs" | jq '. + {"'"$hidden_dir"'/*": "/.local"}')
                    map_dirs_empty=false
                fi
            fi
        done
    fi

    # 更新 JSON 内容
    json_content=$(echo "$json_content" | jq '. + {"Dirs": '"$dirs"'}')
    json_content=$(echo "$json_content" | jq '. + {"Args": ["'${args[@]}'"]}')
    
    # 如果 files 不为空，则添加到 JSON 中
    if [ ${#files[@]} -gt 0 ]; then
        json_content=$(echo "$json_content" | jq '. + {"Files": '"$(printf '%s\n' "${files[@]}" | jq -R . | jq -s .)"'}')
        files_empty=false
    fi

    # 如果 map_dirs 不为空，则添加到 JSON 中
    if ! $map_dirs_empty; then
        json_content=$(echo "$json_content" | jq '. + {"MapDirs": '"$map_dirs"'}')
    fi

    # 如果 ENV_VARS 不为空，则添加到 JSON 中
    if [ ${#ENV_VARS[@]} -gt 0 ]; then
        env_dict=$(printf '%s\n' "${ENV_VARS[@]}" | awk -F '=' '{print "{\""$1"\":\""$2"\"}"}' | jq -s 'add')
        json_content=$(echo "$json_content" | jq '. + {"Env": '"$env_dict"'}')
    fi

    # 写入并格式化 config.json
    echo "$json_content" | jq '.' > config.json
    log "INFO" "config.json generated or updated successfully."
}


run_ops_pkg_load() {
    log "INFO" "Running test"

    while true; do
        # 运行 ops pkg load 并捕获输出
        load_result=$(ops pkg load "$PACKAGE" -c config.json --missing-files 2>&1)

        # 检查是否出现 "No space left on device" 错误
        echo "$load_result" | grep -q "No space left on device"
        no_space_left=$?

        # 获取 "cannot open shared object file" 的文件
        missing_files=$(echo "$load_result" | grep 'cannot open shared object file' | grep -oP 'lib\w+\.so\.\d+')

        if [ $no_space_left -eq 0 ] || [ -n "$missing_files" ]; then
            # 处理 "No space left on device" 错误
            if [ $no_space_left -eq 0 ]; then
                log "WARNING" "No space left on device. Adjusting BaseVolumeSz..."
                if ! jq -e '.BaseVolumeSz' config.json > /dev/null; then
                    # 如果不存在 BaseVolumeSz 字段，添加它
                    jq '.BaseVolumeSz = "2g"' config.json > config_tmp.json && mv config_tmp.json config.json
                    log "INFO" "Added BaseVolumeSz with value 2g to config.json"
                else
                    # 如果存在 BaseVolumeSz 字段，增加其值
                    current_size=$(jq -r '.BaseVolumeSz' config.json | tr -d 'g')
                    new_size=$((current_size + 2))
                    jq --arg new_size "${new_size}g" '.BaseVolumeSz = $new_size' config.json > config_tmp.json && mv config_tmp.json config.json
                    log "INFO" "Increased BaseVolumeSz to ${new_size}g in config.json"
                fi
            fi

            # 处理丢失的共享对象文件
            if [ -n "$missing_files" ]; then
                log "INFO" "find missing files:\n$missing_files"
                paths=$(find / -name "$missing_files" 2>/dev/null)
                if [ -z "$paths" ]; then
                    log "ERROR" "Shared object file $missing_files not found on the system. Please install it manually."
                    exit 1
                fi

                # 优先从 /usr/lib 或 /lib 开头的路径复制
                src_path=$(echo "$paths" | grep -E '^/usr/lib|^/lib' | head -n 1)
                if [ -z "$src_path" ]; then
                    src_path=$(echo "$paths" | head -n 1)
                fi

                dest_path="$LIB_TARGET_DIR/$(basename "$missing_files")"
                cp "$src_path" "$dest_path"
                log "INFO" "$src_path -> $dest_path"
            fi
        else
            # 使用sed过滤missing_files_begin和missing_files_end之间的行并打印
            missing_section=$(echo "$load_result" | sed -n '/missing_files_begin/,/missing_files_end/p')
            echo "Missing Files Section:"
            print_table "$missing_section"
            break
        fi
    done
}

# 主函数
main() {
    # 检查是否提供了命令行参数
    if [ $# -eq 0 ]; then
        usage
    fi

    # 记录开始时间
    start_time=$(date +%s)

    # 获取 -p 和 -e 参数值
    while getopts ":p:e:" opt; do
        case $opt in
            p) PACKAGE="$OPTARG"
            ;;
            e) ENV_VARS+=("$OPTARG")
            ;;
            \?) log "ERROR" "Invalid parameters: -$OPTARG" >&2
                exit 1
            ;;
            :) log "ERROR" "Option -$OPTARG requires a value." >&2
               exit 1
            ;;
        esac
    done

    # 将剩余参数存入命令数组
    shift $((OPTIND - 1))
    cmd=("$@")

    install_tools
    run_strace
    process_result_log
    check_package_contents
    filter_final_result
    copy_files_to_target
    generate_config
    run_ops_pkg_load

    # 打印运行总用时
    end_time=$(date +%s)
    total_time=$((end_time - start_time))
    log "INFO" "Program runtime: $total_time seconds"
}

# 调用主函数
main "$@"
