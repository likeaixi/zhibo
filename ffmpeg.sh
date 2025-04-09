#!/bin/bash

# 定义颜色
green='\033[0;32m'
yellow='\033[0;33m'
red='\033[0;31m'
font='\033[0m'

# 配置文件路径
CONFIG_FILE="/etc/ffmpeg_stream.conf"
LOG_FILE="/var/log/ffmpeg_stream.log"
MAX_LOG_SIZE=5M  # 日志文件最大大小
MAX_LOG_FILES=5   # 保留的日志文件数量

ffmpeg_install() {
    if ! command -v ffmpeg &> /dev/null; then
        echo -e "${yellow}正在安装 FFmpeg...${font}"
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -yq ffmpeg
        elif command -v yum &> /dev/null; then
            sudo yum install -y epel-release
            sudo yum install -y ffmpeg
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm
            sudo dnf install -y ffmpeg
        else
            echo -e "${red}无法确定包管理器，请手动安装 FFmpeg${font}"
            return 1
        fi
        if [ $? -eq 0 ]; then
            echo -e "${green}FFmpeg 安装成功${font}"
        else
            echo -e "${red}FFmpeg 安装失败，请手动安装${font}"
            return 1
        fi
    else
        echo -e "${green}FFmpeg 已安装${font}"
    fi
}

save_config() {
    echo "RTMP_URL=$RTMP_URL" > "$CONFIG_FILE"
    echo "VIDEO_FOLDER=$VIDEO_FOLDER" >> "$CONFIG_FILE"
    echo "BITRATE=$BITRATE" >> "$CONFIG_FILE"
    echo "FRAMERATE=$FRAMERATE" >> "$CONFIG_FILE"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

rotate_log() {
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -gt $(numfmt --from=iec $MAX_LOG_SIZE) ]; then
        for i in $(seq $((MAX_LOG_FILES-1)) -1 1); do
            if [ -f "${LOG_FILE}.$i" ]; then
                mv "${LOG_FILE}.$i" "${LOG_FILE}.$((i+1))"
            fi
        done
        mv "$LOG_FILE" "${LOG_FILE}.1"
        touch "$LOG_FILE"
    fi
}

clean_old_logs() {
    find $(dirname "$LOG_FILE") -name "$(basename "$LOG_FILE")*" -type f | sort -r | tail -n +$((MAX_LOG_FILES+1)) | xargs -r rm
}

stream_start() {
    load_config

    if [ -z "$RTMP_URL" ] || [ -z "$VIDEO_FOLDER" ] || [ -z "$BITRATE" ] || [ -z "$FRAMERATE" ]; then
        read -p "输入你的推流地址和推流码(rtmp协议): " RTMP_URL
        if [[ ! $RTMP_URL =~ ^rtmp:// ]]; then
            echo -e "${red}推流地址不合法，请重新输入！${font}"
            return 1
        fi

        read -p "输入你的视频存放目录 (格式仅支持mp4，需要绝对路径，例如/home/video): " VIDEO_FOLDER
        if [ ! -d "$VIDEO_FOLDER" ]; then
            echo -e "${red}目录不存在，请检查后重新输入！${font}"
            return 1
        fi

        read -p "输入视频比特率 (回车默认 1200k): " BITRATE
        BITRATE=${BITRATE:-1200k}

        read -p "输入视频帧率 (回车默认 30): " FRAMERATE
        FRAMERATE=${FRAMERATE:-30}

        save_config
    fi

    # === 随机参数生成 ===

    # 微亮度/对比度（±0.0001 ~ ±0.0005）
    BRIGHTNESS=$(awk -v r=$RANDOM 'BEGIN{srand(); printf("%.5f", (r % 2 == 0 ? 1 : -1) * (0.0001 + rand() * 0.0004))}')
    CONTRAST=$(awk -v r=$RANDOM 'BEGIN{srand(); printf("%.5f", 1 + (r % 2 == 0 ? 1 : -1) * (rand() * 0.0005))}')

    # 音量调整（1 ± 0.0001~0.0005）
    VOLUME=$(awk -v r=$RANDOM 'BEGIN{srand(); printf("%.5f", 1 + (r % 2 == 0 ? 1 : -1) * (0.0001 + rand() * 0.0004))}')

    # 高频音频频率 (19500Hz ~ 20000Hz)
    FREQ=$(shuf -i 19500-20000 -n 1)

    # 透明度 (alpha 0.001 ~ 0.005)
    ALPHA=$(awk 'BEGIN{srand(); printf("%.4f", 0.001 + rand() * 0.004)}')


    echo -e "${yellow}开始后台推流。${font}"
    nohup bash -c '
        while true; do
            rotate_log
            clean_old_logs
            video_files=("'$VIDEO_FOLDER'"/*.mp4)
            if [ ${#video_files[@]} -eq 0 ]; then
                echo "没有找到mp4文件，请检查并重试..." >> "'$LOG_FILE'"
                sleep 10
                continue
            fi
            for video in "${video_files[@]}"; do
                if [ -f "$video" ]; then
                    # 获取输入分辨率
                    HAS_AUDIO="$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of default=noprint_wrappers=1:nokey=1 "\$video")"
                    RESOLUTION="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "\$video")"
                    DURATION="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "\$video")"
                    echo "正在推流: $video" >> "'$LOG_FILE'"

                    echo "⚙️ Applying Filters:"
                    echo "  Brightness: '$BRIGHTNESS'"
                    echo "  Contrast:   '$CONTRAST'"
                    echo "  Volume:     '$VOLUME'"
                    echo "  Freq:       '$FREQ' Hz"
                    echo "  Alpha:      '$ALPHA'"
                    echo "  Resolution: '$RESOLUTION'"
                    echo "  DURATION: '$DURATION'"
                    echo ""
                    if [ "$HAS_AUDIO" == "audio" ]; then
                      ffmpeg -re -i "$video" \
                       -f lavfi -i "color=black@${ALPHA}:s=\${RESOLUTION}" \
                       -f lavfi -i "sine=frequency=${FREQ}:duration=\${DURATION}:sample_rate=44100" \
                       -filter_complex "\
                       [0:v][1:v]overlay,eq=contrast=${CONTRAST}:brightness=${BRIGHTNESS}[vout]; \
                       [0:a][2:a]amix=inputs=2:duration=first:weights='"1 0.0001"',volume=${VOLUME}[aout]" \
                       -map "[vout]" -map "[aout]" \
                       -c:v libx264 -preset veryfast -tune zerolatency -b:v "'$BITRATE'" -r "'$FRAMERATE'" -g 50 -c:a aac -b:a 128k -f flv "'$RTMP_URL'" 2>> "'$LOG_FILE'" || true
                    else
                    ffmpeg -re -i "$video" \
                                           -f lavfi -i "color=black@${ALPHA}:s=\${RESOLUTION}" \
                                           -f lavfi -i "sine=frequency=${FREQ}:duration=\${DURATION}:sample_rate=44100" \
                                           -filter_complex "\
                                           [0:v][1:v]overlay,eq=contrast=${CONTRAST}:brightness=${BRIGHTNESS}[vout]" \
                                           -map "[vout]" -map 2:a \
                                           -c:v libx264 -preset veryfast -tune zerolatency -b:v "'$BITRATE'" -r "'$FRAMERATE'" -g 50 -c:a aac -b:a 128k -f flv "'$RTMP_URL'" 2>> "'$LOG_FILE'" || true
                    fi

                fi
            done
        done
    ' > ./ffmpeg_stream-`date +%Y-%m-%d`.log  2>&1 &

    echo $! > /var/run/ffmpeg_stream.pid
}

stream_stop() {
    if [ -f /var/run/ffmpeg_stream.pid ]; then
        pid=$(cat /var/run/ffmpeg_stream.pid)
        kill $pid
        rm /var/run/ffmpeg_stream.pid
        echo -e "${yellow}关闭成功，推流即将停止${font}"
    else
        echo -e "${red}没有正在运行的推流进程${font}"
    fi
}

stream_status() {
    if [ -f /var/run/ffmpeg_stream.pid ]; then
        pid=$(cat /var/run/ffmpeg_stream.pid)
        if kill -0 $pid 2>/dev/null; then
            echo -e "${green}推流正在运行 (PID: $pid)${font}"
            echo "最近的日志:"
            tail -n 10 "$LOG_FILE"
            echo "CPU 使用率:"
            ps -p $pid -o %cpu,%mem,cmd
            echo "日志文件大小:"
            du -h "$LOG_FILE"
        else
            echo -e "${red}推流进程不存在，可能已异常退出${font}"
        fi
    else
        echo -e "${yellow}推流未运行${font}"
    fi
}

show_menu() {
    echo -e "${yellow}==== FFmpeg 无人值守循环推流脚本 ====${font}"
    echo -e "${green}1. 安装 FFmpeg${font}"
    echo -e "${green}2. 开始推流${font}"
    echo -e "${green}3. 停止推流${font}"
    echo -e "${green}4. 查看推流状态${font}"
    echo -e "${green}5. 退出${font}"
    echo -e "${yellow}=====================================${font}"
}

main() {
    while true; do
        show_menu
        read -p "请输入选项 (1-5): " choice
        case $choice in
            1)
                ffmpeg_install
                ;;
            2)
                stream_start
                ;;
            3)
                stream_stop
                ;;
            4)
                stream_status
                ;;
            5)
                echo "退出脚本"
                exit 0
                ;;
            *)
                echo -e "${red}无效的选项，请重新选择${font}"
                ;;
        esac
        echo
        read -p "按回车键继续..."
    done
}

main
