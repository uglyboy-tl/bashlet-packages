#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

TEST_PROVIDERS=(agnes)

# 重试测试用：可变请求（requests.post 在用例里被桩化）
provider_flaky_meta() {
  PROVIDER_LABEL="Flaky"
  PROVIDER_CAPS="size:any ref:none seed:no negative:no quality:no style:no n:1"
  PROVIDER_HOST="example.com"
  PROVIDER_FREE=false
}
provider_flaky_auth() { :; }
provider_flaky_endpoint() { :; }
provider_flaky_body() { echo '{"prompt":"x"}'; }
provider_flaky_parse() { IMAGINE_RESULT_TYPE=base64; IMAGINE_RESULTS="iVBORw0KGgo="; }

setup() { _imagine_setup; }

teardown() { _imagine_teardown; }

# ── 离线单元测试（不耗 tokens） ──

@test "unit - 尺寸归一" {
  run size.resolve 1024x768 ''
  [[ $output == "1024x768 4:3" ]]

  run size.resolve 1792*1024 ''
  [[ $output == "1792x1024 16:9" ]]

  run size.resolve '' 16:9
  [[ $output == "1792x1024 16:9" ]]

  run size.resolve '' ''
  [[ $output == "1024x1024 1:1" ]]

  run size.resolve '' 16:9 2k
  [[ $output == "2048x1152 16:9" ]]
  run size.resolve '' '' 2k
  [[ $output == "2048x2048 1:1" ]]
}

@test "unit - 能力映射" {
  run size.cap star 1024x768 4:3 ''
  [[ $output == "1024*768" ]]

  run size.cap fixed 1792x1024 16:9 "1024x1024 1536x1024 1024x1536"
  [[ $output == "1536x1024" ]]

  run size.cap none 1024x768 4:3 ''
  [[ -z $output ]]

  # 直接调 nearest（不经过 size.cap 的动态作用域）
  run size.nearest 1792x1024 "1024x1024 1536x1024 1024x1536"
  [[ $output == "1536x1024" ]]
  run size.nearest 1024x1792 "1024x1024 1536x1024 1024x1536"
  [[ $output == "1024x1536" ]]
}

@test "unit - 质量档位映射到适配器" {
  PROMPT=x SIZE=1024x1024 ASPECT=1:1 COUNT=1 SEED="" NEGATIVE="" STYLE="" REF="" EXTRA_JSON=""
  MODEL=gpt-image-1 QUALITY=2k
  run provider_openai_body
  [[ $(echo "$output" | jq -r '.quality') == "high" ]]
  QUALITY=normal
  run provider_openai_body
  [[ $(echo "$output" | jq -r '.quality') == "medium" ]]

  MODEL=gemini-2.5-flash-image ASPECT=16:9 IMAGE_SIZE=2K
  run provider_google_body
  [[ $(echo "$output" | jq -r '.generationConfig.imageConfig.imageSize') == "2K" ]]
  IMAGE_SIZE=1K
  run provider_google_body
  [[ $(echo "$output" | jq -r '.generationConfig.imageConfig.imageSize') == "1K" ]]
}

@test "unit - 不支持 --quality 2k 时忽略并提示" {
  SIZE=1024x1024 ASPECT=1:1 COUNT=1 SEED="" NEGATIVE="" STYLE="" REF="" QUALITY=2k QUALITY_EXPLICIT=true
  run compose.apply_caps cloudflare
  [[ $status -eq 0 ]]
  [[ $output == *"不支持 --quality 2k"* ]]
}

@test "unit - base_url/via 代理解析" {
  XGET_BASE_URL=""
  run provider.base_url agnes
  [[ $output == "https://apihub.agnes-ai.com" ]]
  run provider.via agnes
  [[ $output == "direct" ]]

  XGET_BASE_URL="https://xget.example"
  run provider.base_url google
  [[ $output == "https://xget.example/ip/gemini" ]]
  run provider.via google
  [[ $output == "https://xget.example/ip/gemini" ]]
}

@test "unit - --extra 解析为 JSON（含点号路径）" {
  run common.extra_json 'prompt_extend=false,n=3,model=x'
  [[ $output == '{"prompt_extend":false,"n":3,"model":"x"}' ]]

  run common.extra_json 'parameters.prompt_extend=false'
  [[ $output == '{"parameters":{"prompt_extend":false}}' ]]
}

@test "unit - 契约：假 provider 可注册并声明能力" {
  provider_fake_meta() {
    PROVIDER_LABEL="Fake"
    PROVIDER_CREDS=(FAKE_KEY)
    PROVIDER_CAPS="size:fixed ref:multi seed:yes negative:no quality:no style:no n:2"
    PROVIDER_SIZES=(1024x1024 1536x1024)
    PROVIDER_HOST="example.com"
    PROVIDER_FREE=false
  }
  provider.register fake
  run provider.cap fake size
  [[ $output == "fixed" ]]
  run provider.cap fake ref
  [[ $output == "multi" ]]
  run provider.cap fake n
  [[ $output == "2" ]]
  run provider.default_model fake
  [[ -z $output ]]
}

@test "unit - 所有 provider 适配器实现完整契约" {
  for name in $(provider.list); do
    for m in meta auth endpoint body parse; do
      declare -F "provider_${name}_${m}" > /dev/null ||
        fail "provider $name 缺少 provider_${name}_${m}"
    done
  done
}

@test "unit - --extra 合并进请求体" {
  provider_stub_meta() {
    PROVIDER_LABEL="Stub"
    PROVIDER_CAPS="size:any ref:none seed:no negative:no quality:no style:no n:1"
    PROVIDER_HOST="example.com"
    PROVIDER_FREE=false
  }
  provider_stub_auth() { :; }
  provider_stub_endpoint() { :; }
  provider_stub_body() { echo '{"prompt":"x"}'; }
  provider_stub_parse() { :; }
  provider.register stub
  PROMPT=x MODEL=m SIZE=1024x1024 ASPECT=1:1 COUNT=1 SEED="" NEGATIVE="" QUALITY="" STYLE="" REF="" EXTRA_JSON='{"seed":7}'
  run compose.build stub
  [[ $output == '{"prompt":"x","seed":7}' ]]
}

@test "unit - compose.init 清掉上一家认证（不串凭证）" {
  requests.auth_bearer "SECRET-LEAK"
  compose.init google > /dev/null 2>&1 || true
  [[ ${_REQUESTS_AUTH[Authorization]:-} != *SECRET-LEAK* ]]
}

@test "unit - 落盘图片校验" {
  printf '\x89PNG\r\n\x1a\n' > "$TEST_DIR/a.png"
  printf '\xff\xd8\xff\xe0' > "$TEST_DIR/b.jpg"
  printf 'RIFF\x00\x00\x00\x00WEBP' > "$TEST_DIR/c.webp"
  printf 'RIFF\x00\x00\x00\x00WAVE' > "$TEST_DIR/d.wav"
  printf 'not an image' > "$TEST_DIR/e.bin"
  : > "$TEST_DIR/empty"
  run common.is_image_file "$TEST_DIR/a.png"; [[ $status -eq 0 ]]
  run common.is_image_file "$TEST_DIR/b.jpg"; [[ $status -eq 0 ]]
  run common.is_image_file "$TEST_DIR/c.webp"; [[ $status -eq 0 ]]
  run common.is_image_file "$TEST_DIR/d.wav"; [[ $status -ne 0 ]]
  run common.is_image_file "$TEST_DIR/e.bin"; [[ $status -ne 0 ]]
  run common.is_image_file "$TEST_DIR/empty"; [[ $status -ne 0 ]]
}

@test "unit - compose.save 失败时回收已写文件" {
  IMAGINE_RESULT_TYPE=url
  IMAGINE_RESULTS=$'http://x/1.png\nhttp://x/2.png'
  _n=0
  requests.download() {
    _n=$((_n + 1))
    if ((_n == 1)); then printf '\x89PNG\r\n\x1a\n' > "$2"; else printf '<html>' > "$2"; fi
  }
  run compose.save "$TEST_DIR/part.png"
  [[ $status -ne 0 ]]
  [[ ! -f $TEST_DIR/part.png ]]
  [[ ! -f $TEST_DIR/part_1.png ]]
}

@test "unit - openai 模型列表过滤器" {
  requests.get() { echo '{"status_code":200,"curl_exit":0,"success":true,"headers":{},"body":""}'; }
  requests.json() { jq -r "$2" <<< '{"data":[{"id":"gpt-image-1"},{"id":"text-embedding-3"}]}'; }
  run provider_openai_models
  [[ $output == "gpt-image-1" ]]
}

@test "unit - compose.save 拒绝非图片" {
  IMAGINE_RESULT_TYPE=url
  IMAGINE_RESULTS="http://x/1.png"
  requests.download() { printf '<html>error</html>' > "$2"; }
  run compose.save "$TEST_DIR/bad.png"
  [[ $status -ne 0 ]]
  [[ ! -f $TEST_DIR/bad.png ]]
}

@test "unit - compose.save 落盘合法图片" {
  IMAGINE_RESULT_TYPE=base64
  IMAGINE_RESULTS="$(printf '\x89PNG\r\n\x1a\n' | base64 -w0)"
  run compose.save "$TEST_DIR/good.png"
  [[ $status -eq 0 ]]
  [[ -f $TEST_DIR/good.png ]]
}

@test "unit - size:fixed 缺候选时快速失败" {
  run size.cap fixed 1024x1024 1:1 ''
  [[ $status -ne 0 ]]
}

@test "unit - size:fixed 降级要提示" {
  SIZE=1792x1024 ASPECT=16:9 COUNT=1 SEED="" NEGATIVE="" STYLE="" REF="" QUALITY=normal
  run compose.apply_caps openrouter
  [[ $status -eq 0 ]]
  [[ $output == *"就近映射"* ]]
}

@test "unit - emit_json 成功/失败" {
  PROVIDER=agnes MODEL=m SIZE=1024x1024 SIZE_REQUESTED=1024x768 ASPECT=4:3 COUNT=1 IMAGINE_ATTEMPTS=1
  IMAGINE_FILES=("$TEST_DIR/a.png")
  IMAGINE_ERROR=""
  run compose.emit_json 0
  [[ $(echo "$output" | jq -r .ok) == true ]]
  [[ $(echo "$output" | jq -r '.files[0]') == "$TEST_DIR/a.png" ]]
  [[ $(echo "$output" | jq -r .requested_size) == 1024x768 ]]
  IMAGINE_ERROR="boom"
  run compose.emit_json 1
  [[ $(echo "$output" | jq -r .ok) == false ]]
  [[ $(echo "$output" | jq -r .error) == boom ]]
}

@test "unit - 尺寸/宽高比非法输入报错" {
  run size.resolve 1024 ''; [[ $status -ne 0 ]]
  run size.resolve 0x0 ''; [[ $status -ne 0 ]]
  run size.resolve 1024x768x2 ''; [[ $status -ne 0 ]]
  run size.resolve 1024x768 bogus; [[ $status -ne 0 ]]
  run size.from_aspect 16:9:1; [[ $status -ne 0 ]]
  run size.from_aspect 1024x576; [[ $status -ne 0 ]]
}

@test "unit - size:aspect 显式尺寸要提示" {
  SIZE=1024x768 ASPECT=4:3 SIZE_EXPLICIT=true COUNT=1 SEED="" NEGATIVE="" STYLE="" REF="" QUALITY=normal
  run compose.apply_caps google
  [[ $status -eq 0 ]]
  [[ $output == *"只按宽高比"* ]]
}

@test "unit - 多图路径拼接" {
  [[ $(compose._numbered /tmp/x/out 0) == "/tmp/x/out" ]]
  [[ $(compose._numbered /tmp/x/out 1) == "/tmp/x/out_1" ]]
  [[ $(compose._numbered /tmp/x/out.png 1) == "/tmp/x/out_1.png" ]]
  [[ $(compose._numbered /tmp/a.b/out 1) == "/tmp/a.b/out_1" ]]
}

@test "unit - compose.save 失败不破坏既有文件" {
  IMAGINE_RESULT_TYPE=url
  IMAGINE_RESULTS="http://x/1.png"
  echo "OLD" > "$TEST_DIR/keep.png"
  requests.download() { printf '<html>' > "$2"; }
  run compose.save "$TEST_DIR/keep.png"
  [[ $status -ne 0 ]]
  [[ $(cat "$TEST_DIR/keep.png") == "OLD" ]]
}

@test "unit - models_live 强制走活 API / 无 API 时失败" {
  provider_agnes_models() { printf 'live-a\nlive-b\n'; }
  run provider.models_live agnes
  [[ $status -eq 0 ]]
  [[ $output == $'live-a\nlive-b' ]]
  run provider.models_live zai
  [[ $status -ne 0 ]]
}

@test "cli - models --live 对无列表 API 失败" {
  run bash "$PROJECT_ROOT/imagine.sh" models cloudflare --live
  [[ $status -ne 0 ]]
}

@test "unit - provider.models 缓存优先于活 API" {
  registry.ensure
  local cache="$(registry.cache)"
  printf '\n[providers.google]\nmodels = "cached-model-1 cached-model-2"\n' >> "$cache"
  registry.reload
  provider_google_models() { echo "live-model"; }
  run provider.models google
  [[ $status -eq 0 ]]
  [[ $output == $'cached-model-1\ncached-model-2' ]]
}

@test "unit - registry 种子与读取" {
  registry.ensure
  local cache="$(registry.cache)"
  [[ -s $cache ]]
  grep -q '^\[providers\.agnes\]' "$cache"
  registry.reload
  [[ "$(registry.get agnes default_model)" == "agnes-image-2.1-flash" ]]
  [[ "$(provider.default_model agnes)" == "agnes-image-2.1-flash" ]]
}

@test "unit - registry 覆盖适配器默认" {
  registry.ensure
  local cache="$(registry.cache)"
  sed -i 's/agnes-image-2.1-flash/agnes-x/' "$cache"
  registry.reload
  [[ "$(provider.default_model agnes)" == "agnes-x" ]]
}

@test "unit - registry 缺某家时回退适配器" {
  registry.ensure
  local cache="$(registry.cache)"
  awk '/^\[providers\.agnes\]/{skip=1;next} /^\[/{skip=0} !skip' "$cache" > "$cache.tmp" && mv "$cache.tmp" "$cache"
  registry.reload
  [[ "$(provider.default_model agnes)" == "agnes-image-2.1-flash" ]]
}

@test "unit - registry 坏数据不覆盖缓存" {
  registry.ensure
  local cache="$(registry.cache)" before
  before="$(cat "$cache")"
  requests.init() { :; }
  requests.get() { printf '{"status_code":200,"curl_exit":0,"success":true,"headers":{},"body":""}'; }
  requests.status_code() { echo 200; }
  requests.success() { echo true; }
  requests.text() { printf 'not a registry'; }
  requests.headers() { printf ''; }
  run registry.fetch
  [[ $status -ne 0 ]]
  [[ "$(cat "$cache")" == "$before" ]]
}

@test "unit - registry 远端正常时原子替换" {
  registry.ensure
  local body='[providers.agnes]
default_model = "agnes-remote"
'
  requests.init() { :; }
  requests.get() { printf '{"status_code":200,"curl_exit":0,"success":true,"headers":{},"body":""}'; }
  requests.status_code() { echo 200; }
  requests.success() { echo true; }
  requests.text() { printf '%s' "$body"; }
  requests.headers() { printf ''; }
  registry.fetch
  registry.reload
  [[ "$(registry.get agnes default_model)" == "agnes-remote" ]]
}

@test "unit - registry TTL 以尝试时间为准" {
  registry.ensure
  run registry.is_fresh
  [[ $status -ne 0 ]] # 种子未回源过 → 不新鲜
  touch "$(registry.attempt_marker)"
  run registry.is_fresh
  [[ $status -eq 0 ]]
}

@test "unit - registry diff 摘要" {
  local old=$'providers.agnes.default_model=a\nproviders.cloudflare.models=m1 m2'
  local new=$'providers.agnes.default_model=b\nproviders.cloudflare.models=m2 m3'
  run registry.print_diff "$old" "$new"
  [[ $status -eq 0 ]]
  [[ $output == *"a -> b"* ]]
  [[ $output == *"+ m3"* ]]
  [[ $output == *"- m1"* ]]
}

@test "unit - 模型解析优先级" {
  registry.ensure
  local cache="$(registry.cache)"
  sed -i 's/agnes-image-2.1-flash/agnes-registry/' "$cache"
  registry.reload
  [[ "$(provider.resolve_model agnes '' '')" == "agnes-registry" ]]
  AGNES_IMAGE_MODEL=agnes-env
  [[ "$(provider.resolve_model agnes '' '')" == "agnes-env" ]]
  [[ "$(provider.resolve_model agnes '' agnes-cli)" == "agnes-cli" ]]
  unset AGNES_IMAGE_MODEL
}

@test "unit - 可恢复失败自动重试" {
  provider.register flaky
  local counter="$TEST_DIR/calls"
  echo 0 > "$counter"
  requests.post() {
    local n
    n=$(($(cat "$counter") + 1))
    echo "$n" > "$counter"
    if ((n == 1)); then
      printf '{"status_code":503,"curl_exit":0,"success":false,"headers":{},"body":"e30="}'
    else
      printf '{"status_code":200,"curl_exit":0,"success":true,"headers":{},"body":"%s"}' "$(printf '{"ok":true}' | base64 -w0)"
    fi
  }
  IMAGINE_RETRY=1
  PROMPT=x MODEL=m SIZE=1024x1024 ASPECT=1:1 COUNT=1 SEED="" NEGATIVE="" QUALITY="" STYLE="" REF="" EXTRA_JSON=""
  run compose.generate flaky "$TEST_DIR/flaky.png"
  [[ $status -eq 0 ]]
  [[ $(cat "$counter") -eq 2 ]]
  [[ -f $TEST_DIR/flaky.png ]]
}

@test "unit - 4xx 不重试" {
  provider.register flaky
  local counter="$TEST_DIR/calls"
  echo 0 > "$counter"
  requests.post() {
    echo "$(($(cat "$counter") + 1))" > "$counter"
    printf '{"status_code":400,"curl_exit":0,"success":false,"headers":{},"body":"%s"}' "$(printf '{"error":{"message":"bad"}}' | base64 -w0)"
  }
  IMAGINE_RETRY=2
  PROMPT=x MODEL=m SIZE=1024x1024 ASPECT=1:1 COUNT=1 SEED="" NEGATIVE="" QUALITY="" STYLE="" REF="" EXTRA_JSON=""
  run compose.generate flaky "$TEST_DIR/never.png"
  [[ $status -ne 0 ]]
  [[ $(cat "$counter") -eq 1 ]]
  [[ ! -f $TEST_DIR/never.png ]]
}

@test "unit - 能力边界：不支持参考图时报错" {
  SIZE=1024x1024 ASPECT=1:1 COUNT=1 SEED="" NEGATIVE="" QUALITY="" STYLE="" REF=ref.png
  run compose.apply_caps zai
  [[ $status -ne 0 ]]
}

@test "unit - 数量上限自动收敛" {
  SIZE=1024x1024 ASPECT=1:1 COUNT=5 SEED="" NEGATIVE="" QUALITY="" STYLE="" REF=""
  run compose.apply_caps cloudflare
  [[ $status -eq 0 ]]
  # run 在子 shell 中执行，全局变量不会回传，故另跑一次验证 COUNT
  SIZE=1024x1024 ASPECT=1:1 COUNT=5 SEED="" NEGATIVE="" QUALITY="" STYLE="" REF=""
  compose.apply_caps cloudflare
  [[ $COUNT -eq 1 ]]

  # size:none：显式尺寸被清空
  SIZE=512x512 ASPECT=1:1 SIZE_EXPLICIT=true COUNT=1 SEED="" NEGATIVE="" QUALITY="" STYLE="" REF=""
  compose.apply_caps cloudflare
  [[ -z $SIZE ]]
}

# ── CLI 离线测试 ──

@test "cli - providers 表格列出适配器" {
  run bash "$PROJECT_ROOT/imagine.sh" providers
  [[ $status -eq 0 ]]
  [[ $output == *agnes* ]]
  [[ $output == *cloudflare* ]]
  [[ $output == *openrouter* ]]
}

@test "cli - models 走 registry 清单（无 API 的 provider）" {
  run bash "$PROJECT_ROOT/imagine.sh" models cloudflare
  [[ $status -eq 0 ]]
  [[ $output == *flux-1-schnell* ]]
  [[ $output == *flux-2-dev* ]]
}

@test "cli - update 在 OFF 时提示并退出非零" {
  run bash "$PROJECT_ROOT/imagine.sh" update
  [[ $status -ne 0 ]]
  [[ $output == *IMAGINE_REGISTRY_OFF* ]]
}

@test "cli - --json 失败也在 stdout 给 JSON" {
  run bash -c "bash \"$PROJECT_ROOT/imagine.sh\" --json --provider nonexistent -p x 2>/dev/null"
  [[ $status -ne 0 ]]
  [[ $(echo "$output" | jq -r .ok) == false ]]
  [[ $(echo "$output" | jq -r .provider) == nonexistent ]]
}

@test "cli - --json 校验失败时 error 非空" {
  run bash -c "bash \"$PROJECT_ROOT/imagine.sh\" --json --provider agnes -p x -s 1024 2>/dev/null"
  [[ $status -ne 0 ]]
  [[ $(echo "$output" | jq -r .ok) == false ]]
  [[ -n $(echo "$output" | jq -r .error) ]]
}

@test "cli - --json 非数字 count 早退也给 JSON" {
  run bash -c "bash \"$PROJECT_ROOT/imagine.sh\" --json --provider agnes -n abc 2>/dev/null"
  [[ $status -ne 0 ]]
  [[ $(echo "$output" | jq -r .ok) == false ]]
}

@test "cli - models 多个位置参数报错" {
  run bash "$PROJECT_ROOT/imagine.sh" models agnes google
  [[ $status -ne 0 ]]
}

@test "error - 缺少提示词" {
  run bash "$PROJECT_ROOT/imagine.sh" --provider agnes
  [[ $status -ne 0 ]]
}

@test "error - 无效提供商" {
  run bash "$PROJECT_ROOT/imagine.sh" --provider nonexistent -p "test"
  [[ $status -ne 0 ]]
}

@test "error - 不存在的提示词文件" {
  run bash "$PROJECT_ROOT/imagine.sh" -P /nonexistent/file.txt
  [[ $status -ne 0 ]]
}

@test "error - 非法 seed" {
  run bash "$PROJECT_ROOT/imagine.sh" --provider agnes -p "x" --seed abc
  [[ $status -ne 0 ]]
}

# ── 生图测试（按 provider 参数化） ──

# 没有 key 就 skip 真实生图用例（干净 checkout 上 tools/test 不应因缺 key 变红）
_have_agnes_key() { [[ -n ${AGNES_API_KEY:-} ]] || grep -qs '^AGNES_API_KEY=' "$PROJECT_ROOT/.env"; }

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

# 免费层可能瞬时超时/限流，失败后重试一次
_imagine() {
  run bash "$PROJECT_ROOT/imagine.sh" "$@"
  [[ $status -eq 0 ]] && return 0
  sleep 5
  run bash "$PROJECT_ROOT/imagine.sh" "$@"
  return $status
}

@test "generate - 合并测试 (尺寸+种子+负面提示)" {
  _have_agnes_key || skip "AGNES_API_KEY not set"
  for p in "${TEST_PROVIDERS[@]}"; do
    local outfile="$TEST_DIR/${p}_combo.png"

    _imagine \
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
  _have_agnes_key || skip "AGNES_API_KEY not set"
  local refimg="$PROJECT_ROOT/test/assets/ref.png"

  [[ -f $refimg ]] || skip "assets/ref.png not found"

  for p in "${TEST_PROVIDERS[@]}"; do
    local outfile="$TEST_DIR/${p}_ref.png"

    _imagine \
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
