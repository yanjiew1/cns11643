#!/bin/bash

set -euo pipefail

# 取得指令碼所在目錄
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/Data"
TMP_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cns11643-sync-$$"
MANIFEST_URL="https://www.cns11643.gov.tw/opendata/release.txt"

TODAY=$(date +%Y-%m-%d)
MANIFEST_FILE="${TMP_DIR}/release.txt"

mkdir -p "${TMP_DIR}"

IS_TTY=false
[[ -t 1 ]] && IS_TTY=true

log() {
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

download_file() {
    local url="$1"
    local output_file="$2"
    local show_progress="${3:-false}"

    if [[ "${show_progress}" == "true" ]] && [[ "${IS_TTY}" == "true" ]]; then
        curl -fSL --retry 3 --retry-delay 1 --progress-bar "${url}" -o "${output_file}"
    else
        curl -fsSL --retry 3 --retry-delay 1 "${url}" -o "${output_file}"
    fi
}

# 下載最新的更新說明，並從中解析所有上層資源的下載網址
log "Downloading manifest from ${MANIFEST_URL}"
download_file "${MANIFEST_URL}" "${MANIFEST_FILE}"

mapfile -t RESOURCE_URLS < <(
    grep -aoE 'https://www\.cns11643\.gov\.tw/opendata/[A-Za-z0-9._%()+-]+' "${MANIFEST_FILE}" | awk '!seen[$0]++'
)

if [[ ${#RESOURCE_URLS[@]} -eq 0 ]]; then
    echo 'No downloadable resources found.'
    exit 1
fi

log "Found ${#RESOURCE_URLS[@]} resources in manifest"

# 下載所有資源到臨時目錄
for resource_url in "${RESOURCE_URLS[@]}"; do
    filename="${resource_url##*/}"
    temp_file="${TMP_DIR}/${filename}"

    log "Downloading ${filename}"
    if ! download_file "${resource_url}" "${temp_file}" "true"; then
        echo "Failed to download file ${resource_url}"
        exit 2
    fi
    log "Downloaded ${filename}"
done

# 進入 git 工作目錄
log "Preparing git working tree"
cd "${SCRIPT_DIR}"

# 先把 Data 從 index 中移除，再重建 Data 目錄
git rm -r --cached "Data" >/dev/null 2>&1 || true
rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

# 還原最新檔案到工作目錄
cp "${TMP_DIR}/release.txt" "${OUTPUT_DIR}/release.txt"
cp "${TMP_DIR}/release.txt" "${SCRIPT_DIR}/release.txt"

for resource_url in "${RESOURCE_URLS[@]}"; do
    filename="${resource_url##*/}"
    temp_file="${TMP_DIR}/${filename}"

    if [[ "${filename}" == *.zip ]]; then
        extract_dir="${filename%.zip}"
        output_extract_dir="${OUTPUT_DIR}/${extract_dir}"
        log "Extracting ${filename} to Data/${extract_dir}/"
        rm -rf "${output_extract_dir}"
        mkdir -p "${output_extract_dir}"

        if ! 7za x -y -o"${output_extract_dir}" "${temp_file}" >/dev/null; then
            echo "Failed to extract file ${temp_file}"
            exit 1
        fi
    else
        log "Copying ${filename} to Data/"
        cp "${temp_file}" "${OUTPUT_DIR}/${filename}"
    fi
done

# 只加入需要提交的內容
git add "Data" "release.txt"

# 處理日期
VERSION=$(grep -aoE '[0-9]{4}-[0-9]{2}-[0-9]{2}' "${OUTPUT_DIR}/release.txt" | head -n1)
[ -z "${VERSION}" ] && VERSION="unknown"

# 處理 commit
COMMIT_MESSAGE="Update to the version ${VERSION}, fetched on ${TODAY}"
if git diff --cached --quiet; then
    log 'No changes to commit.'
else
    log "Committing changes: ${COMMIT_MESSAGE}"
    git commit -m "${COMMIT_MESSAGE}"
    log 'Pushing changes to origin main'
    git push -u origin main
fi

# 清理臨時目錄
rm -rf "${TMP_DIR}"

