#!/usr/bin/env bats

load 'test_helper/common-setup'

TEST_PROVIDERS=(agnes)

setup() {
  _common_setup
  cd "$PROJECT_ROOT"
  TEST_DIR=$(mktemp -d)
}

teardown() {
  rm -rf "${TEST_DIR:-}"
}

# ── 错误处理（不耗 tokens） ──

@test "error - 缺少提示词" {
  run bash src/imagine.sh --provider agnes
  [[ $status -ne 0 ]]
}

@test "error - 无效提供商" {
  run bash src/imagine.sh --provider nonexistent -p "test"
  [[ $status -ne 0 ]]
}

@test "error - 不存在的提示词文件" {
  run bash src/imagine.sh -P /nonexistent/file.txt
  [[ $status -ne 0 ]]
}

# ── 生图测试（按 provider 参数化） ──

_check_ratio() {
  [[ -f $1 ]] || return 1
  local d=$(file "$1") w h
  [[ "$d" == *"image data"* ]] || return 1
  d=$(echo "$d" | grep -oE '[0-9]+ ?x ?[0-9]+' | tail -1)
  w="${d%%[xX]*}" h="${d#*[xX]}"
  w="${w// /}" h="${h// /}"
  local r=$(( (w * 100) / h ))

  local exp
  if [[ $2 == *:* ]]; then
    case $2 in
      "4:3")  exp=133 ;; "3:4")  exp=75  ;;
      "16:9") exp=175 ;; "9:16") exp=57  ;;
      "1:1")  exp=100 ;;
      "2.35:1") exp=234 ;;
      *) return 1 ;;
    esac
  else
    local ew="${2%%[xX*]*}" eh="${2##*[xX*]}"
    exp=$(( (ew * 100) / eh ))
  fi

  echo "ratio=$r (expected ~$exp)"
  local d=$(( r - exp ))
  [[ ${d#-} -le 5 ]]
}

@test "generate - 合并测试 (尺寸+种子+负面提示)" {
  for p in "${TEST_PROVIDERS[@]}"; do
    local outfile="$TEST_DIR/${p}_combo.png"

    run bash src/imagine.sh \
      --provider "$p" \
      -p "a cute cat" \
      -s "1024x768" \
      --seed 42 \
      --negative-prompt "blurry,low quality" \
      -o "$outfile"

    echo "[$p] exit=$status"
    [[ $status -eq 0 ]] || return 1
    _check_ratio "$outfile" "1024x768" || return 1
  done
}

@test "generate - 参考图" {
  local refimg="$PROJECT_ROOT/test/assets/ref.png"

  [[ -f $refimg ]] || skip "assets/ref.png not found"

  for p in "${TEST_PROVIDERS[@]}"; do
    local outfile="$TEST_DIR/${p}_ref.png"

    run bash src/imagine.sh \
      --provider "$p" \
      -p "a cute cat" \
      --ref "$refimg" \
      --ar "16:9" \
      -o "$outfile"

    echo "[$p] exit=$status"
    [[ $status -eq 0 ]] || return 1
    _check_ratio "$outfile" "16:9" || return 1
  done
}
