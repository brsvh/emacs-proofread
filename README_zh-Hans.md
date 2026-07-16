<p align="right"><a href="README.md">English</a> · <strong>简体中文</strong></p>

```
Copyright (c)  2026 Bingshan Chang.
Permission is granted to copy, distribute and/or modify this document
under the terms of the GNU Free Documentation License, Version 1.3
or any later version published by the Free Software Foundation;
with no Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.
A copy of the license is included in the section entitled "GNU
Free Documentation License".
```

# proofread

Proofread 为 GNU Emacs 提供异步、上下文感知的校对功能。它从普通文本、注释或文档字符串中提取自然语言，将其拆分为大小受限的文本块，并发送给
LLM 或本地 LanguageTool
后端。拼写、语法、风格及其他问题会以诊断项形式显示，用户可以逐项查看、忽略或直接在原处修正。请求异步运行，因此校对不会阻塞编辑。

<div align="center">

https://github.com/user-attachments/assets/3c77758b-00ab-48e2-9e23-e54e8845d251

</div>

## 快速开始

### 安装

`proofread` 包依赖 GNU Emacs 和 GNU ELPA `llm`，其中同时包含核心、LLM 和 LanguageTool
库。LanguageTool 本身是可选运行时依赖，仅在使用 LanguageTool checker 时需要；核心与 LLM
后端不会加载或启动它。LanguageTool 后端可以复用任意兼容的本地 v2 HTTP 服务；只有自动启动功能额外要求
`languagetool-http-server` 位于 `exec-path`。可选的 `proofread-popup` 0.1.1 包还要求
`proofread` 0.2.0 或更高版本，并依赖 `posframe`。

克隆本仓库并将其中的软件包目录加入 `load-path`：

```sh
git clone https://github.com/brsvh/emacs-proofread.git
```

```elisp
(add-to-list 'load-path "/path/to/emacs-proofread/lisp/proofread")
(add-to-list 'load-path "/path/to/emacs-proofread/lisp/proofread-popup")
(require 'proofread)
```

### 构建软件包

仓库中的 `Makefile` 可构建核心包 `proofread` 和可选包 `proofread-popup`。构建使用 GNU Make、GNU tar
和 GNU Emacs；进行字节编译时，上文列出的包依赖必须对所用 Emacs 可见。请从仓库根目录运行这些命令：

```sh
make all
make proofread
make proofread-popup
make clean
```

`make all` 会构建两个包。包专用目标只构建其中一个包，`make clean` 会删除生成文件。可通过 `EMACS` 选择其他 Emacs
可执行文件，例如 `make EMACS=/path/to/emacs all`。

构建输出位于 `lisp/` 和 `dist/` 下：包元数据、autoload 文件、字节编译文件，以及符合 ELPA
规范的源码归档。`make proofread-compile` 或 `make proofread-archive`
等单阶段目标仍可用于发布工作，但普通使用通常只需要上面的汇总目标。

### 配置

> [!WARNING]
> 当前主分支的代码 API 并不稳定，建议您使用 v0.1.0 tag。

Proofread 的派发由 profile 驱动。先定义 `proofread-profiles`，再用 `proofread-profile` 选中一个
profile，并加载该 profile 使用的后端库。Profile 是命名语言配置，包含 `:language`、`:display-language`
和有序的 `:checkers`。每个 checker 都有稳定的 `:name`，选择一个已注册的 `:backend`，并携带可选的后端局部
`:options`。

将 `:language` 设为 `"en-US"` 或 `"zh-CN"` 这样的机器可读语言代码。将 `:display-language` 设为 LLM
提示词使用的自然语言名称，例如 `"English"` 或 `"Simplified Chinese"`。

#### 最小配置（`llm`）

一个最小 LLM 配置只需要一个 profile 和一个 `llm` checker。以下示例用本地 Ollama 模型 `qwen3.5:4b`
检查英文文本：

```elisp
(require 'proofread)
(require 'proofread-llm)
(require 'llm-ollama)

(defvar qwen3.5-4b (make-llm-ollama :chat-model "qwen3.5:4b"))

(setq proofread-profiles
      `((english
         :language "en-US"
         :display-language "English"
         :checkers (( :name ollama-qwen
                      :backend llm
                      :options ( :provider ,qwen3.5-4b
                                 :provider-identity "ollama:qwen3.5:4b"))))))

(setq proofread-profile 'english)

(add-hook 'text-mode-hook #'proofread-mode)
(add-hook 'prog-mode-hook #'proofread-mode)
```

#### `llm` backend 的进一步配置

LLM checker 从 checker 局部 `:options` 读取 provider 和请求行为。Checker 选项只覆盖该 checker 对应的
`proofread-llm-*` 默认值。

每次 LLM 请求都会优先把 profile 中非 `nil` 的 `:display-language` 作为目标语言提示；若其为 `nil`，则回退到
`:language`。两者都为 `nil` 时，不添加目标语言提示。

对于本地模型，本文档只介绍 Ollama。使用 `llm` 提供的 provider，并为 checker 设置稳定且不含敏感信息的 provider 标识：

```elisp
(require 'llm-ollama)

(defvar qwen3.5-4b-checker
  `( :name ollama-qwen
     :backend llm
     :options ( :provider ,(make-llm-ollama :chat-model "qwen3.5:4b")
                :provider-identity "ollama:qwen3.5:4b"
                :diagnostic-passes 1)))
```

对于远程模型，请将凭据保存在 `auth-source` 或其他安全设施中。以下 OpenAI 示例从 `auth-source` 读取 key，并使用不包含
key 的稳定 provider 标识：

```elisp
(require 'auth-source)
(require 'llm-openai)

(defvar gpt-5.4-checker
  `( :name openai
     :backend llm
     :options ( :provider ,(make-llm-openai :key (auth-source-pick-first-password
                                                  :host "api.openai.com")
                                            :chat-model "gpt-5.4")
                :provider-identity "openai:gpt-5.4"
                :source-label "gpt-5.4"
                :response-strategy auto
                :diagnostic-passes 1)))
```

当 checker 局部 `:source-label` 非 `nil` 时，Proofread 会在弹窗消息中使用它；否则依次使用
`proofread-llm-source-label`、provider 的 `llm-name`，最后回退为 `llm`。部分 provider 的
`llm-name` 返回 provider 系列而非精确的 chat model，因此需要准确模型名时应显式设置
`:source-label`。Checker 局部显式的 `nil` 会绕过全局标签，并为该 checker 恢复自动 provider 命名。

`proofread-llm-response-strategy` 的默认值是 `auto`：当 provider 声明支持 JSON 响应时使用 JSON
Schema，否则回退到仅由提示词约束的 JSON。如果提供 `:instructions-function`，也应提供稳定的
`:instructions-identity`，以便指令变化时缓存身份同步变化。

`proofread-llm-request-timeout` 是由 Proofread 管理的请求 watchdog，默认值为 `120` 秒；将其设为
`nil` 可在全局禁用 watchdog，所有非 `nil` 值都必须是正数。只要 checker 局部 `:options` 中存在
`:request-timeout` 键，就会覆盖全局值，因此显式的 `nil` 会只为该 checker 禁用 watchdog。超时设置只控制请求的
存活时间，不参与缓存兼容性；修改它不会使其他方面仍兼容的缓存结果失效。启用 `proofread-mode` 时，当前的
`proofread-llm-request-timeout` 值也会成为 buffer-local 的
`llm-request-plz-connect-timeout`。关闭模式会恢复原先的局部绑定；若原先没有局部绑定，则重新继承届时的全局值。

更完整的 provider 配置请参考上游
[`llm.el` provider 文档](https://github.com/ahyatt/llm#setting-up-providers)。

#### `languagetool` backend 的配置

单语言 LanguageTool 配置同样只需要一个 profile 和一个 `languagetool` checker。LanguageTool 优先使用
checker 局部 `:options` 中的 `:language`；只要该键存在，即使显式设为表示自动检测的
`nil`，也会采用该值。该键不存在时，才回退到 profile 中机器可读的 `:language`。非 `nil` 值必须是 `en-US`、`zh-CN`
或 `de-DE` 这样的代码，而不是 `"English"` 这样的显示名称。LanguageTool 绝不会收到 profile 的
`:display-language`：

```elisp
(require 'proofread)
(require 'proofread-languagetool)

(defvar languagetool-checker
  '( :name languagetool
     :backend languagetool
     :options ( :language "en-US"
                :level picky)))

(setq proofread-profiles
      `((english-languagetool
         :language "en-US"
         :display-language "English"
         :checkers (,languagetool-checker))))

(setq proofread-profile 'english-languagetool)

(add-hook 'text-mode-hook #'proofread-mode)
(add-hook 'prog-mode-hook #'proofread-mode)
```

若要自动启动本地 LanguageTool，请确保 `languagetool-http-server` 位于 `exec-path`，或将
`proofread-languagetool-command` 设为它的绝对路径。服务 URL
和生命周期设置是会话全局的。`:language`、`:level`、`:preferred-variants`、规则列表、分类列表、`:mother-tongue`
和 `:enabled-only` 等请求选项应放在 checker 中。LanguageTool 服务 URL 仍是全局设置；不要在 checker 中放入
`:url` 并期待每个 profile 使用不同服务。

运行 `M-x proofread-languagetool-start-server` 可以显式复用或启动配置的服务，即使自动启动已禁用也可以这样做。运行
`M-x proofread-languagetool-stop-server` 只会停止当前 Emacs 会话所拥有的服务，绝不会停止外部服务。

当 LanguageTool checker 的 `:language` 为 `nil` 时，后端会发送 `language=auto`。此时应在该
checker 中设置 `:preferred-variants`，以便启用依赖语言变体的拼写词典，例如：

```elisp
'( :language nil
   :preferred-variants ("en-US" "de-DE"))
```

本地开源服务会让被检查的文本留在本机，但不包含 LanguageTool 仅在云端提供的 AI 规则。若未另外配置 fastText
模型，自动语言检测也会较弱，因此显式语言代码是最可预测的配置。上游细节请参阅官方的[本地服务指南](https://dev.languagetool.org/http-server.html)和
[HTTP API](https://languagetool.org/http-api/)。

#### 为多种语言启用不同的后端

更复杂的配置通常为每种语言定义一个 profile。每个 profile 可以选择不同的后端集合，或不同的后端局部选项。以下示例为英文使用 OpenAI 加
LanguageTool，为简体中文使用本地 Ollama 加 LanguageTool：

```elisp
(require 'proofread)
(require 'proofread-llm)
(require 'proofread-languagetool)
(require 'auth-source)
(require 'llm-openai)
(require 'llm-ollama)

(defvar gpt-5.4-checker
  `( :name openai
     :backend llm
     :options ( :provider ,(make-llm-openai :key (auth-source-pick-first-password
                                                  :host "api.openai.com")
                                            :chat-model "gpt-5.4")
                :provider-identity "openai:gpt-5.4"
                :source-label "gpt-5.4"
                :response-strategy auto
                :diagnostic-passes 1)))

(defvar languagetool-english-checker
  '( :name languagetool
     :backend languagetool
     :options ( :language "en-US"
                :level picky)))

(defvar languagetool-chinese-checker
  '( :name languagetool
     :backend languagetool
     :options ( :language "zh-CN"
                :level picky)))

(defvar qwen3.5-4b-checker
  `( :name ollama-qwen
     :backend llm
     :options ( :provider ,(make-llm-ollama :chat-model "qwen3.5:4b")
                :provider-identity "ollama:qwen3.5:4b"
                :diagnostic-passes 1)))

(setq proofread-profiles
      `((english
         :language "en-US"
         :display-language "English"
         :checkers (,gpt-5.4-checker
                    ,languagetool-english-checker))
        (chinese
         :language "zh-CN"
         :display-language "Simplified Chinese"
         :checkers (,qwen3.5-4b-checker
                    ,languagetool-chinese-checker))))

(setq proofread-profile 'english)
```

通过设置 `proofread-profile` 切换 profile：

```elisp
(setq proofread-profile 'chinese)
```

来自不同 checker 的诊断项在内部仍然彼此独立。用户界面会把指向同一实时范围和同一文本的诊断项分组，保留每个 checker
的消息，并去重相同的修改建议文本。每个分组中的 checker 标签、消息、修改建议和修正选项都按 profile 所声明的 `:checkers`
顺序排列，不受异步请求完成顺序影响。

#### 为单个缓冲区选择 profile

`proofread-profile` 仍是普通的全局默认值。若要只在一个缓冲区中选择不同的
profile，而不改变其他缓冲区使用的默认值，请将它设为缓冲区局部变量：

```elisp
(setq-local proofread-profile 'chinese)
```

改变缓冲区选中的 profile，或从该 profile 中移除 checker，本身不会立即清除诊断项。下一次显式检查时，Proofread
会移除受检范围内由所选 profile 已不再包含的 checker 产生的诊断项，即使当前 checker
均未返回任何诊断项。受检范围以外的诊断项保持不变；仍在 profile 中的 checker 的诊断项会一直显示，直到相应的新结果生效。

文件局部和目录局部值使用 Emacs 的常规确认流程。如果信任某个确定的 profile 值，可以只将这个值显式加入允许列表：

```elisp
(add-to-list 'safe-local-variable-values
             '(proofread-profile . chinese))
```

不要把 `proofread-profile` 的任意值都标记为安全。Profile 可能选择远程
checker，而自动检查随后可能把缓冲区内容发送给该提供程序。

在兼容 0.1 版配置期间，`nil` 表示已配置的废弃单后端设置仍然生效，并不表示无条件禁用派发。若要显式禁用派发，请选择一个 `:checkers`
列表为空的命名 profile：

```elisp
(add-to-list 'proofread-profiles '(disabled :checkers nil))
(setq-local proofread-profile 'disabled)
```

使用这个 profile 执行显式检查时，不会派发后端请求，但会移除受检范围内由 profile 检查产生的诊断项。该范围以外的诊断项保持不变。由
profile owner 退出所触发的清理，不会影响通过底层 API 临时加入且在其他方面仍有效的诊断项。

#### 从 0.1 版迁移

`proofread-backend` 和 `proofread-language` 已在 0.2 版中废弃。请把后端选择移入各 checker 的
`:backend`，把语言提示移入 profile 的 `:language`，再用 `proofread-profile` 选择该 profile。当
`proofread-profile` 为 `nil` 时，旧变量暂时仍可用于兼容，但新配置不应再设置它们。

`proofread-targets` 控制每个缓冲区中要检查的文本：

| 值                        | 行为                                                                        |
| ------------------------- | --------------------------------------------------------------------------- |
| `auto`                    | 在派生自 `prog-mode` 的模式中检查注释和文档字符串，在其他模式中检查全部文本 |
| `all`                     | 检查全部文本                                                                |
| `comments`                | 仅检查注释                                                                  |
| `docstrings`              | 仅检查文档字符串                                                            |
| `comments-and-docstrings` | 检查注释和文档字符串                                                        |

该选项设置后会成为缓冲区局部变量。若要更改新缓冲区的默认值，请使用 `setq-default`，例如：

```elisp
(setq-default proofread-targets 'all)
```

### 运行检查

执行 `M-x proofread-mode` 后，默认行为是在空闲 1
秒后检查当前缓冲区在所有显示该缓冲区的活动窗口中的可见范围的并集。启用模式、编辑、滚动或更改窗口配置都会调度一次检查。URL、电子邮件地址、不可见文本，以及由
`proofread-ignored-faces` 或 `proofread-ignored-properties` 选中的文本不会发送到后端。

自动检查仅覆盖可见文本。若要明确检查其他范围，请使用
`proofread-check-at-point`、`proofread-check-region`、`proofread-check-buffer` 或
`proofread-check-visible-range`。这四个命令都要求启用
`proofread-mode`。缓冲区命令遵循窄化范围；光标处命令检查光标处已准备好发送请求的文本块，而非仅检查一个单词。

通过验证的诊断项使用 `proofread-face` 显示。可用 `proofread-next` 和 `proofread-previous` 导航，用
`proofread-describe` 查看完整详情，或用 `proofread-show-buffer-diagnostics`
在源窗口下方打开诊断列表。在该列表中，`RET` 跳转到诊断项，`SPC` 或 `C-o` 在另一个窗口中预览诊断项，`n` 或 `p` 在诊断项之间移动。

### 修正错误

将光标置于诊断项上并运行 `M-x proofread-correct-at-point`。只有一个修改建议时会直接应用；有多个修改建议时使用
`completing-read` 选择，因此 Vertico 等补全界面无需额外集成即可工作。在提交编辑之前，Proofread
会验证诊断项仍然有效、原文未改变，并确保替换不会破坏注释或文档字符串的分隔符。

运行 `M-x proofread-ignore` 可忽略一项诊断。忽略记录在当前 Emacs 会话中持续有效，并会从所有启用 Proofread
的缓冲区中过滤语义相同的诊断项。

<div align="center">

**检查并修正光标处文本**

https://github.com/user-attachments/assets/8ce73c38-69af-4b51-bcc8-f913753751fc

</div>

## 高级功能

### `proofread-popup`

`proofread-popup` 是基于 Posframe 的可选前端。加载该库后，`proofread-popup-mode` 会在每个缓冲区中自动跟随
`proofread-mode`：

```elisp
(require 'proofread-popup)
```

当光标位于诊断项上时，该前端会在诊断范围起点上方的子框架中逐条显示诊断消息，并在光标离开时隐藏子框架。默认会等待光标保持空闲 `0.5`
秒，再根据届时光标处的诊断创建或更新子框架；等待期间发生的移动和诊断变化会合并为一次更新。将 `proofread-popup-delay` 设为 `0`
可恢复立即更新行为，例如使用 `(setq proofread-popup-delay 0)` 或 Customize。每条消息都会带有后端来源前缀：LLM
checker 使用其有效来源标签，LanguageTool 显示 `languagetool`。来源标签使用加粗且跟随主题的强调
face。弹窗不显示修改建议，也不提供操作。在终端及其他无法使用子框架的环境中，弹窗不可用。运行 `M-x proofread-popup-mode`
可在当前缓冲区中禁用或重新启用该自动集成。也可以使用 `proofread-popup-enabled`、`proofread-popup-delay` 和
`proofread-popup-max-width` 控制其显示。

### 批量修正

Proofread 不会仅因后端返回诊断就改写文本。只有用户显式调用以下命令，才会执行批量修正：

- `proofread-correct-region` 修正完全包含在活动区域中的诊断项。
- `proofread-correct-buffer` 修正当前缓冲区可访问部分中的诊断项。
- `proofread-correct-visible-range` 修正所有可见范围中的诊断项。

不含修改建议的诊断项会被跳过；与较早诊断项重叠的后续诊断项也会被跳过。具有多个修改建议的诊断项仍会逐项询问。整批修改以单个撤销步骤原子地应用；若任何替换失败，整批修改都会回滚。

<div align="center">

**检查并修正选定区域**

https://github.com/user-attachments/assets/efd63fe7-eafe-410f-b785-93da7e227424

**检查并修正可见范围**

https://github.com/user-attachments/assets/2dda228e-f85c-4500-aea0-549500628c6e

</div>

## 命令

核心模式未定义默认按键绑定。以下命令可通过 `M-x` 调用，也可由用户自行绑定：

| 命令                                | 说明                                         |
| ----------------------------------- | -------------------------------------------- |
| `proofread-mode`                    | 切换当前缓冲区中的 Proofread 次要模式        |
| `proofread-check-at-point`          | 检查光标处已准备好发送请求的文本块           |
| `proofread-check-region`            | 检查活动区域                                 |
| `proofread-check-buffer`            | 检查当前缓冲区的可访问部分                   |
| `proofread-check-visible-range`     | 检查显示当前缓冲区的所有活动窗口中的可见范围 |
| `proofread-show-buffer-diagnostics` | 打开当前缓冲区的诊断列表                     |
| `proofread-next`                    | 移动到下一项诊断，到末尾不循环               |
| `proofread-previous`                | 移动到上一项诊断，到开头不循环               |
| `proofread-describe`                | 在帮助缓冲区中说明光标处的诊断项             |
| `proofread-correct-at-point`        | 应用光标处诊断项的修改建议                   |
| `proofread-correct-region`          | 修正活动区域中包含的诊断项                   |
| `proofread-correct-buffer`          | 修正缓冲区可访问部分中的诊断项               |
| `proofread-correct-visible-range`   | 修正可见范围中包含的诊断项                   |
| `proofread-ignore`                  | 在当前 Emacs 会话中忽略光标处的诊断项        |
| `proofread-clear`                   | 清除当前缓冲区中的诊断项及其覆盖层           |
| `proofread-clear-cache`             | 清除当前缓冲区的诊断缓存                     |
| `proofread-show-buffer-requests`    | 开始记录并显示某个缓冲区的后端请求           |

在请求列表中，`RET` 或 `C-m` 调用 `proofread-show-request` 以显示完整的请求生命周期。在诊断列表中，`RET` 或
`C-m` 调用 `proofread-goto-diagnostic`，`SPC` 或 `C-o` 则调用
`proofread-show-diagnostic`。

## 自定义选项

运行 `M-x customize-group RET proofread RET` 可编辑核心选项：

| 选项                                      | 默认值 | 用途                                                             |
| ----------------------------------------- | ------ | ---------------------------------------------------------------- |
| `proofread-auto-check`                    | `t`    | 在启用模式、编辑和窗口活动后安排检查；设置后为缓冲区局部变量     |
| `proofread-targets`                       | `auto` | 选择全部文本、注释或文档字符串；设置后为缓冲区局部变量           |
| `proofread-docstring-predicate-functions` | `nil`  | 添加识别文档字符串的谓词函数；设置后为缓冲区局部变量             |
| `proofread-idle-delay`                    | `1.0`  | 自动检查前等待的空闲秒数                                         |
| `proofread-inhibit-progress-messages`     | `t`    | 抑制后台进度消息，但不抑制错误或显式命令反馈                     |
| `proofread-max-chunk-size`                | `2000` | 限制每个校对文本块的字符数                                       |
| `proofread-context-size`                  | `300`  | 限制文本块每侧发送的上下文字符数                                 |
| `proofread-context-sentences-before`      | `1`    | 限制文本块之前的逻辑上下文句数                                   |
| `proofread-context-sentences-after`       | `1`    | 限制文本块之后的逻辑上下文句数                                   |
| `proofread-max-concurrent-requests`       | `8`    | 限制每个缓冲区的活动后端请求数                                   |
| `proofread-profiles`                      | `nil`  | 定义命名的多后端 profile                                         |
| `proofread-profile`                       | `nil`  | 选择命名 profile                                                 |
| `proofread-llm-provider`                  | `nil`  | LLM checker 省略 `:provider` 时使用的默认提供程序                |
| `proofread-llm-response-strategy`         | `auto` | LLM checker 省略 `:response-strategy` 时使用的默认响应策略       |
| `proofread-llm-request-timeout`           | `120`  | 设置 LLM watchdog 与 mode-local plz 连接超时；`nil` 表示禁用两者 |
| `proofread-llm-provider-identity`         | `nil`  | LLM checker 省略 `:provider-identity` 时使用的默认稳定标识       |
| `proofread-llm-source-label`              | `nil`  | 默认诊断来源标签；`nil` 表示使用有效 provider 名称               |
| `proofread-llm-max-diagnostic-passes`     | `3`    | LLM checker 省略 `:diagnostic-passes` 时使用的默认诊断轮数       |
| `proofread-llm-instructions-function`     | `nil`  | LLM checker 省略 `:instructions-function` 时使用的默认附加说明   |
| `proofread-llm-instructions-identity`     | `nil`  | LLM checker 省略说明标识时使用的默认稳定标识                     |
| `proofread-cache-max-entries`             | `128`  | 限制每个缓冲区的 LRU 缓存条目数；`0` 表示禁用缓存                |
| `proofread-request-log-max-records`       | `100`  | 限制每个受监视缓冲区保留的记录数                                 |
| `proofread-ignored-faces`                 | `nil`  | 排除 `face` 属性与指定 `face` 匹配的文本                         |
| `proofread-ignored-properties`            | `nil`  | 排除指定文本属性之一为非 `nil` 的文本                            |

LanguageTool 库另有一个 `proofread-languagetool` Customize 组：

| 选项                                         | 默认值                                   | 用途                                           |
| -------------------------------------------- | ---------------------------------------- | ---------------------------------------------- |
| `proofread-languagetool-server-url`          | `http://127.0.0.1:8081/v2`               | 选择本地或由外部管理的 v2 API 端点             |
| `proofread-languagetool-auto-start`          | `t`                                      | 端点不可用时启动当前会话共享的本地服务         |
| `proofread-languagetool-command`             | `languagetool-http-server`               | 选择托管启动所用的可执行文件或 argv 前缀       |
| `proofread-languagetool-config-file`         | `PROOFREAD_LANGUAGETOOL_CONFIG` 或 `nil` | 向服务传递可选的本机 Java properties 文件      |
| `proofread-languagetool-startup-timeout`     | `15.0`                                   | 限制托管服务的整体启动等待时间                 |
| `proofread-languagetool-health-timeout`      | `3.0`                                    | 限制单次服务健康探测的等待时间                 |
| `proofread-languagetool-request-timeout`     | `10.0`                                   | 限制单次 `/check` 请求的等待时间               |
| `proofread-languagetool-level`               | `default`                                | checker 省略 `:level` 时使用的默认检查级别     |
| `proofread-languagetool-preferred-variants`  | `nil`                                    | checker 省略 `:preferred-variants` 时的默认值  |
| `proofread-languagetool-mother-tongue`       | `nil`                                    | checker 省略 `:mother-tongue` 时的默认值       |
| `proofread-languagetool-enabled-rules`       | `nil`                                    | checker 省略 `:enabled-rules` 时的默认值       |
| `proofread-languagetool-disabled-rules`      | `nil`                                    | checker 省略 `:disabled-rules` 时的默认值      |
| `proofread-languagetool-enabled-categories`  | `nil`                                    | checker 省略 `:enabled-categories` 时的默认值  |
| `proofread-languagetool-disabled-categories` | `nil`                                    | checker 省略 `:disabled-categories` 时的默认值 |
| `proofread-languagetool-enabled-only`        | `nil`                                    | checker 省略 `:enabled-only` 时的默认策略      |

启用 `proofread-languagetool-enabled-only`
时必须至少启用一个规则或分类，且不能同时配置禁用规则或分类。语言、检查级别、语言变体、母语、规则和分类设置都会进入后端缓存标识，因此修改检查策略后不会复用旧策略生成的结果。

可选前端还定义了 `proofread-popup-enabled`（默认值为 `t`）、`proofread-popup-delay`（默认值为 `0.5`
秒，`0` 表示立即更新）和 `proofread-popup-max-width`（默认值为 `80`）。可使用
`proofread-face`、`proofread-current-face`、`proofread-popup-face`、`proofread-popup-source-face`
和 `proofread-popup-border-face` 自定义诊断外观。

### 调整并发数

`proofread-max-concurrent-requests` 控制每个缓冲区中的活动请求数。默认值为
`8`；额外请求会在队列中等待。当提供程序实施速率限制，或希望降低本地模型的负载时，可以调低该值：

```elisp
(setq proofread-max-concurrent-requests 2)
```

设为 `0` 时，缓存命中仍然可用，但不会发送新的后端请求。若要进一步降低成本，可将 `proofread-llm-max-diagnostic-passes`
从默认的 `3` 调低到 `1`。

## 行为与注意事项

- 请求异步运行。只有当文本、上下文、校对目标范围和提供程序配置仍与原始请求匹配时，才会应用返回结果；编辑导致的过期结果会被丢弃。
- 远程 LLM 提供程序或非回环 LanguageTool 服务会接收选中的文本及有限的周边上下文，并可能收取使用费用。
- 请求监视功能会为调试保留源文本、生成的提示词文本或 HTTP 请求参数，以及 provider 响应；这些字段可能包含敏感的缓冲区内容。
- 请求日志事件和显示记录不会包含原始 checker `:options`、provider 对象、backend handle
  和其他不透明的后端局部对象。记录的 URL 仅保留 origin（scheme、host 和 port）；后端错误及相关警告只保留 condition
  种类。Checker fingerprint 只从安全的 identity 摘要派生，不读取原始选项。Proofread
  不会递归检查不透明对象来猜测其中的机密字段。
- `proofread-show-buffer-requests`
  从调用时开始记录后续请求，并使用当时处于活动或排队状态的请求初始化日志。它无法恢复已经完成的请求。
- `proofread-clear`
  会清除当前诊断，但不会清除缓存或进行中的请求，因此后续返回的结果可能使诊断再次出现。`proofread-clear-cache`
  只清除缓存。若要停止所有工作并清理状态，请禁用 `proofread-mode`。
- 若外部管理的 LanguageTool 服务在 URL 不变的情况下升级或更换模型，缓存无法自动识别该变化。此时请运行
  `proofread-clear-cache`。
- 由 `proofread-ignore` 创建的记录仅在当前 Emacs 会话中持续有效；这些记录不会保存，也没有用于移除记录的命令。

## Nix 用户指南

Nix 用户可以通过 flake 的默认 overlay 将这两个包添加到 Emacs 包集合中。例如，NixOS 配置可以这样写：

```nix
{
  inputs.emacs-proofread.url = "git+https://github.com/brsvh/emacs-proofread.git";
  inputs.nixpkgs.url = "git+https://github.com/NixOS/nixpkgs?ref=nixos-unstable";

  outputs =
    { emacs-proofread, nixpkgs, ... }:
    {
      nixosConfigurations.HOSTNAME =
        nixpkgs.lib.nixosSystem
          {
            modules = [
              (
                { pkgs, ... }:
                {
                  environment.systemPackages = [((with pkgs; emacsPackagesFor emacs-pgtk).emacsWithPackages(epkgs: with epkgs; [ proofread proofread-popup]))];
                  nixpkgs.overlays = [ emacs-proofread.overlays.default ];
                }
              )
            ];
            system = "x86_64-linux";
          };
    };
}
```

如果只需要核心包，请移除 `epkgs.proofread-popup`。`epkgs.proofread` derivation 仍是普通 Emacs
包，不会把 LanguageTool 或 Java 作为运行时依赖传播给用户。

仅在仓库开发环境中，默认的 `nix develop` shell 和 flake 提供的 Emacs 启动器会将锁定的 Nixpkgs
LanguageTool 服务加入 PATH。其开发专用 `languagetool-http-server` wrapper 启用了 1,000
句本地缓存。当设置 `proofread-languagetool-config-file` 时，该显式 properties 文件会取代 wrapper
仅包含缓存设置的默认配置，并完整控制服务配置。

在支持的系统上，flake 还提供开箱即用的启动器，它们使用临时、干净的初始化目录启动 Emacs。请在仓库根目录通过 `nix flake show`
查找合适的启动器，然后使用 `nix run` 运行它。

这些开发启动器会让包出现在 `load-path` 中，并让 LanguageTool 服务出现在 `exec-path` 中；它们不会自动加载或配置
Proofread。

## AI 辅助声明

本项目中的部分代码、测试和文档是在 AI 工具的辅助下开发的。所有由 AI
生成的输出均由维护者审查，并在必要时进行了修改。维护者仍对最终内容负责。没有任何机密信息、私人用户数据或其他敏感信息被有意提供给 AI 工具。

## 项目许可证

emacs-proofread 是自由软件：您可以根据自由软件基金会发布的 GNU 通用公共许可证第 3
版，或（由您选择）任何后续版本的条款，重新分发和/或修改它。

您应该已经随 emacs-proofread 一同收到 GNU 通用公共许可证的副本。如果没有，请参阅
<https://www.gnu.org/licenses/>。

## GNU Free Documentation License

<details>
<summary>展开这里以查看“GNU Free Documentation License”。</summary>

```text

                GNU Free Documentation License
                 Version 1.3, 3 November 2008


 Copyright (C) 2000, 2001, 2002, 2007, 2008 Free Software Foundation, Inc.
     <https://fsf.org/>
 Everyone is permitted to copy and distribute verbatim copies
 of this license document, but changing it is not allowed.

 0. PREAMBLE

 The purpose of this License is to make a manual, textbook, or other
 functional and useful document "free" in the sense of freedom: to
 assure everyone the effective freedom to copy and redistribute it,
 with or without modifying it, either commercially or noncommercially.
 Secondarily, this License preserves for the author and publisher a way
 to get credit for their work, while not being considered responsible
 for modifications made by others.

 This License is a kind of "copyleft", which means that derivative
 works of the document must themselves be free in the same sense.  It
 complements the GNU General Public License, which is a copyleft
 license designed for free software.

 We have designed this License in order to use it for manuals for free
 software, because free software needs free documentation: a free
 program should come with manuals providing the same freedoms that the
 software does.  But this License is not limited to software manuals;
 it can be used for any textual work, regardless of subject matter or
 whether it is published as a printed book.  We recommend this License
 principally for works whose purpose is instruction or reference.


 1. APPLICABILITY AND DEFINITIONS

 This License applies to any manual or other work, in any medium, that
 contains a notice placed by the copyright holder saying it can be
 distributed under the terms of this License.  Such a notice grants a
 world-wide, royalty-free license, unlimited in duration, to use that
 work under the conditions stated herein.  The "Document", below,
 refers to any such manual or work.  Any member of the public is a
 licensee, and is addressed as "you".  You accept the license if you
 copy, modify or distribute the work in a way requiring permission
 under copyright law.

 A "Modified Version" of the Document means any work containing the
 Document or a portion of it, either copied verbatim, or with
 modifications and/or translated into another language.

 A "Secondary Section" is a named appendix or a front-matter section of
 the Document that deals exclusively with the relationship of the
 publishers or authors of the Document to the Document's overall
 subject (or to related matters) and contains nothing that could fall
 directly within that overall subject.  (Thus, if the Document is in
 part a textbook of mathematics, a Secondary Section may not explain
 any mathematics.)  The relationship could be a matter of historical
 connection with the subject or with related matters, or of legal,
 commercial, philosophical, ethical or political position regarding
 them.

 The "Invariant Sections" are certain Secondary Sections whose titles
 are designated, as being those of Invariant Sections, in the notice
 that says that the Document is released under this License.  If a
 section does not fit the above definition of Secondary then it is not
 allowed to be designated as Invariant.  The Document may contain zero
 Invariant Sections.  If the Document does not identify any Invariant
 Sections then there are none.

 The "Cover Texts" are certain short passages of text that are listed,
 as Front-Cover Texts or Back-Cover Texts, in the notice that says that
 the Document is released under this License.  A Front-Cover Text may
 be at most 5 words, and a Back-Cover Text may be at most 25 words.

 A "Transparent" copy of the Document means a machine-readable copy,
 represented in a format whose specification is available to the
 general public, that is suitable for revising the document
 straightforwardly with generic text editors or (for images composed of
 pixels) generic paint programs or (for drawings) some widely available
 drawing editor, and that is suitable for input to text formatters or
 for automatic translation to a variety of formats suitable for input
 to text formatters.  A copy made in an otherwise Transparent file
 format whose markup, or absence of markup, has been arranged to thwart
 or discourage subsequent modification by readers is not Transparent.
 An image format is not Transparent if used for any substantial amount
 of text.  A copy that is not "Transparent" is called "Opaque".

 Examples of suitable formats for Transparent copies include plain
 ASCII without markup, Texinfo input format, LaTeX input format, SGML
 or XML using a publicly available DTD, and standard-conforming simple
 HTML, PostScript or PDF designed for human modification.  Examples of
 transparent image formats include PNG, XCF and JPG.  Opaque formats
 include proprietary formats that can be read and edited only by
 proprietary word processors, SGML or XML for which the DTD and/or
 processing tools are not generally available, and the
 machine-generated HTML, PostScript or PDF produced by some word
 processors for output purposes only.

 The "Title Page" means, for a printed book, the title page itself,
 plus such following pages as are needed to hold, legibly, the material
 this License requires to appear in the title page.  For works in
 formats which do not have any title page as such, "Title Page" means
 the text near the most prominent appearance of the work's title,
 preceding the beginning of the body of the text.

 The "publisher" means any person or entity that distributes copies of
 the Document to the public.

 A section "Entitled XYZ" means a named subunit of the Document whose
 title either is precisely XYZ or contains XYZ in parentheses following
 text that translates XYZ in another language.  (Here XYZ stands for a
 specific section name mentioned below, such as "Acknowledgements",
 "Dedications", "Endorsements", or "History".)  To "Preserve the Title"
 of such a section when you modify the Document means that it remains a
 section "Entitled XYZ" according to this definition.

 The Document may include Warranty Disclaimers next to the notice which
 states that this License applies to the Document.  These Warranty
 Disclaimers are considered to be included by reference in this
 License, but only as regards disclaiming warranties: any other
 implication that these Warranty Disclaimers may have is void and has
 no effect on the meaning of this License.

 2. VERBATIM COPYING

 You may copy and distribute the Document in any medium, either
 commercially or noncommercially, provided that this License, the
 copyright notices, and the license notice saying this License applies
 to the Document are reproduced in all copies, and that you add no
 other conditions whatsoever to those of this License.  You may not use
 technical measures to obstruct or control the reading or further
 copying of the copies you make or distribute.  However, you may accept
 compensation in exchange for copies.  If you distribute a large enough
 number of copies you must also follow the conditions in section 3.

 You may also lend copies, under the same conditions stated above, and
 you may publicly display copies.


 3. COPYING IN QUANTITY

 If you publish printed copies (or copies in media that commonly have
 printed covers) of the Document, numbering more than 100, and the
 Document's license notice requires Cover Texts, you must enclose the
 copies in covers that carry, clearly and legibly, all these Cover
 Texts: Front-Cover Texts on the front cover, and Back-Cover Texts on
 the back cover.  Both covers must also clearly and legibly identify
 you as the publisher of these copies.  The front cover must present
 the full title with all words of the title equally prominent and
 visible.  You may add other material on the covers in addition.
 Copying with changes limited to the covers, as long as they preserve
 the title of the Document and satisfy these conditions, can be treated
 as verbatim copying in other respects.

 If the required texts for either cover are too voluminous to fit
 legibly, you should put the first ones listed (as many as fit
 reasonably) on the actual cover, and continue the rest onto adjacent
 pages.

 If you publish or distribute Opaque copies of the Document numbering
 more than 100, you must either include a machine-readable Transparent
 copy along with each Opaque copy, or state in or with each Opaque copy
 a computer-network location from which the general network-using
 public has access to download using public-standard network protocols
 a complete Transparent copy of the Document, free of added material.
 If you use the latter option, you must take reasonably prudent steps,
 when you begin distribution of Opaque copies in quantity, to ensure
 that this Transparent copy will remain thus accessible at the stated
 location until at least one year after the last time you distribute an
 Opaque copy (directly or through your agents or retailers) of that
 edition to the public.

 It is requested, but not required, that you contact the authors of the
 Document well before redistributing any large number of copies, to
 give them a chance to provide you with an updated version of the
 Document.


 4. MODIFICATIONS

 You may copy and distribute a Modified Version of the Document under
 the conditions of sections 2 and 3 above, provided that you release
 the Modified Version under precisely this License, with the Modified
 Version filling the role of the Document, thus licensing distribution
 and modification of the Modified Version to whoever possesses a copy
 of it.  In addition, you must do these things in the Modified Version:

 A. Use in the Title Page (and on the covers, if any) a title distinct
    from that of the Document, and from those of previous versions
    (which should, if there were any, be listed in the History section
    of the Document).  You may use the same title as a previous version
    if the original publisher of that version gives permission.
 B. List on the Title Page, as authors, one or more persons or entities
    responsible for authorship of the modifications in the Modified
    Version, together with at least five of the principal authors of the
    Document (all of its principal authors, if it has fewer than five),
    unless they release you from this requirement.
 C. State on the Title page the name of the publisher of the
    Modified Version, as the publisher.
 D. Preserve all the copyright notices of the Document.
 E. Add an appropriate copyright notice for your modifications
    adjacent to the other copyright notices.
 F. Include, immediately after the copyright notices, a license notice
    giving the public permission to use the Modified Version under the
    terms of this License, in the form shown in the Addendum below.
 G. Preserve in that license notice the full lists of Invariant Sections
    and required Cover Texts given in the Document's license notice.
 H. Include an unaltered copy of this License.
 I. Preserve the section Entitled "History", Preserve its Title, and add
    to it an item stating at least the title, year, new authors, and
    publisher of the Modified Version as given on the Title Page.  If
    there is no section Entitled "History" in the Document, create one
    stating the title, year, authors, and publisher of the Document as
    given on its Title Page, then add an item describing the Modified
    Version as stated in the previous sentence.
 J. Preserve the network location, if any, given in the Document for
    public access to a Transparent copy of the Document, and likewise
    the network locations given in the Document for previous versions
    it was based on.  These may be placed in the "History" section.
    You may omit a network location for a work that was published at
    least four years before the Document itself, or if the original
    publisher of the version it refers to gives permission.
 K. For any section Entitled "Acknowledgements" or "Dedications",
    Preserve the Title of the section, and preserve in the section all
    the substance and tone of each of the contributor acknowledgements
    and/or dedications given therein.
 L. Preserve all the Invariant Sections of the Document,
    unaltered in their text and in their titles.  Section numbers
    or the equivalent are not considered part of the section titles.
 M. Delete any section Entitled "Endorsements".  Such a section
    may not be included in the Modified Version.
 N. Do not retitle any existing section to be Entitled "Endorsements"
    or to conflict in title with any Invariant Section.
 O. Preserve any Warranty Disclaimers.

 If the Modified Version includes new front-matter sections or
 appendices that qualify as Secondary Sections and contain no material
 copied from the Document, you may at your option designate some or all
 of these sections as invariant.  To do this, add their titles to the
 list of Invariant Sections in the Modified Version's license notice.
 These titles must be distinct from any other section titles.

 You may add a section Entitled "Endorsements", provided it contains
 nothing but endorsements of your Modified Version by various
 parties--for example, statements of peer review or that the text has
 been approved by an organization as the authoritative definition of a
 standard.

 You may add a passage of up to five words as a Front-Cover Text, and a
 passage of up to 25 words as a Back-Cover Text, to the end of the list
 of Cover Texts in the Modified Version.  Only one passage of
 Front-Cover Text and one of Back-Cover Text may be added by (or
 through arrangements made by) any one entity.  If the Document already
 includes a cover text for the same cover, previously added by you or
 by arrangement made by the same entity you are acting on behalf of,
 you may not add another; but you may replace the old one, on explicit
 permission from the previous publisher that added the old one.

 The author(s) and publisher(s) of the Document do not by this License
 give permission to use their names for publicity for or to assert or
 imply endorsement of any Modified Version.


 5. COMBINING DOCUMENTS

 You may combine the Document with other documents released under this
 License, under the terms defined in section 4 above for modified
 versions, provided that you include in the combination all of the
 Invariant Sections of all of the original documents, unmodified, and
 list them all as Invariant Sections of your combined work in its
 license notice, and that you preserve all their Warranty Disclaimers.

 The combined work need only contain one copy of this License, and
 multiple identical Invariant Sections may be replaced with a single
 copy.  If there are multiple Invariant Sections with the same name but
 different contents, make the title of each such section unique by
 adding at the end of it, in parentheses, the name of the original
 author or publisher of that section if known, or else a unique number.
 Make the same adjustment to the section titles in the list of
 Invariant Sections in the license notice of the combined work.

 In the combination, you must combine any sections Entitled "History"
 in the various original documents, forming one section Entitled
 "History"; likewise combine any sections Entitled "Acknowledgements",
 and any sections Entitled "Dedications".  You must delete all sections
 Entitled "Endorsements".


 6. COLLECTIONS OF DOCUMENTS

 You may make a collection consisting of the Document and other
 documents released under this License, and replace the individual
 copies of this License in the various documents with a single copy
 that is included in the collection, provided that you follow the rules
 of this License for verbatim copying of each of the documents in all
 other respects.

 You may extract a single document from such a collection, and
 distribute it individually under this License, provided you insert a
 copy of this License into the extracted document, and follow this
 License in all other respects regarding verbatim copying of that
 document.


 7. AGGREGATION WITH INDEPENDENT WORKS

 A compilation of the Document or its derivatives with other separate
 and independent documents or works, in or on a volume of a storage or
 distribution medium, is called an "aggregate" if the copyright
 resulting from the compilation is not used to limit the legal rights
 of the compilation's users beyond what the individual works permit.
 When the Document is included in an aggregate, this License does not
 apply to the other works in the aggregate which are not themselves
 derivative works of the Document.

 If the Cover Text requirement of section 3 is applicable to these
 copies of the Document, then if the Document is less than one half of
 the entire aggregate, the Document's Cover Texts may be placed on
 covers that bracket the Document within the aggregate, or the
 electronic equivalent of covers if the Document is in electronic form.
 Otherwise they must appear on printed covers that bracket the whole
 aggregate.


 8. TRANSLATION

 Translation is considered a kind of modification, so you may
 distribute translations of the Document under the terms of section 4.
 Replacing Invariant Sections with translations requires special
 permission from their copyright holders, but you may include
 translations of some or all Invariant Sections in addition to the
 original versions of these Invariant Sections.  You may include a
 translation of this License, and all the license notices in the
 Document, and any Warranty Disclaimers, provided that you also include
 the original English version of this License and the original versions
 of those notices and disclaimers.  In case of a disagreement between
 the translation and the original version of this License or a notice
 or disclaimer, the original version will prevail.

 If a section in the Document is Entitled "Acknowledgements",
 "Dedications", or "History", the requirement (section 4) to Preserve
 its Title (section 1) will typically require changing the actual
 title.


 9. TERMINATION

 You may not copy, modify, sublicense, or distribute the Document
 except as expressly provided under this License.  Any attempt
 otherwise to copy, modify, sublicense, or distribute it is void, and
 will automatically terminate your rights under this License.

 However, if you cease all violation of this License, then your license
 from a particular copyright holder is reinstated (a) provisionally,
 unless and until the copyright holder explicitly and finally
 terminates your license, and (b) permanently, if the copyright holder
 fails to notify you of the violation by some reasonable means prior to
 60 days after the cessation.

 Moreover, your license from a particular copyright holder is
 reinstated permanently if the copyright holder notifies you of the
 violation by some reasonable means, this is the first time you have
 received notice of violation of this License (for any work) from that
 copyright holder, and you cure the violation prior to 30 days after
 your receipt of the notice.

 Termination of your rights under this section does not terminate the
 licenses of parties who have received copies or rights from you under
 this License.  If your rights have been terminated and not permanently
 reinstated, receipt of a copy of some or all of the same material does
 not give you any rights to use it.


 10. FUTURE REVISIONS OF THIS LICENSE

 The Free Software Foundation may publish new, revised versions of the
 GNU Free Documentation License from time to time.  Such new versions
 will be similar in spirit to the present version, but may differ in
 detail to address new problems or concerns.  See
 https://www.gnu.org/licenses/.

 Each version of the License is given a distinguishing version number.
 If the Document specifies that a particular numbered version of this
 License "or any later version" applies to it, you have the option of
 following the terms and conditions either of that specified version or
 of any later version that has been published (not as a draft) by the
 Free Software Foundation.  If the Document does not specify a version
 number of this License, you may choose any version ever published (not
 as a draft) by the Free Software Foundation.  If the Document
 specifies that a proxy can decide which future versions of this
 License can be used, that proxy's public statement of acceptance of a
 version permanently authorizes you to choose that version for the
 Document.

 11. RELICENSING

 "Massive Multiauthor Collaboration Site" (or "MMC Site") means any
 World Wide Web server that publishes copyrightable works and also
 provides prominent facilities for anybody to edit those works.  A
 public wiki that anybody can edit is an example of such a server.  A
 "Massive Multiauthor Collaboration" (or "MMC") contained in the site
 means any set of copyrightable works thus published on the MMC site.

 "CC-BY-SA" means the Creative Commons Attribution-Share Alike 3.0
 license published by Creative Commons Corporation, a not-for-profit
 corporation with a principal place of business in San Francisco,
 California, as well as future copyleft versions of that license
 published by that same organization.

 "Incorporate" means to publish or republish a Document, in whole or in
 part, as part of another Document.

 An MMC is "eligible for relicensing" if it is licensed under this
 License, and if all works that were first published under this License
 somewhere other than this MMC, and subsequently incorporated in whole or
 in part into the MMC, (1) had no cover texts or invariant sections, and
 (2) were thus incorporated prior to November 1, 2008.

 The operator of an MMC Site may republish an MMC contained in the site
 under CC-BY-SA on the same site at any time before August 1, 2009,
 provided the MMC is eligible for relicensing.


 ADDENDUM: How to use this License for your documents

 To use this License in a document you have written, include a copy of
 the License in the document and put the following copyright and
 license notices just after the title page:

     Copyright (c)  YEAR  YOUR NAME.
     Permission is granted to copy, distribute and/or modify this document
     under the terms of the GNU Free Documentation License, Version 1.3
     or any later version published by the Free Software Foundation;
     with no Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.
     A copy of the license is included in the section entitled "GNU
     Free Documentation License".

 If you have Invariant Sections, Front-Cover Texts and Back-Cover Texts,
 replace the "with...Texts." line with this:

     with the Invariant Sections being LIST THEIR TITLES, with the
     Front-Cover Texts being LIST, and with the Back-Cover Texts being LIST.

 If you have Invariant Sections without Cover Texts, or some other
 combination of the three, merge those two alternatives to suit the
 situation.

 If your document contains nontrivial examples of program code, we
 recommend releasing these examples in parallel under your choice of
 free software license, such as the GNU General Public License,
 to permit their use in free software.

```

</details>
