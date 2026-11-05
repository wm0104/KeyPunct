# KeyPunct

Apple 简体拼音键盘（26 键与九宫格）中文状态下，**单独按一次标点键**插入英文半角标点；其它行为不变。

- 包 id：`com.wm0104.keypunct`，dylib 装到 `/Library/MobileSubstrate/DynamicLibraries/KeyPunct.dylib`
- 注入范围：`Filter.Bundles = ("com.apple.UIKit")`（键盘在 App 自己的进程里，UIKeyboardImpl 属于 UIKitCore）
- 设置面板：`/Library/PreferenceBundles/KeyPunctPrefs.bundle`，入口 `/Library/PreferenceLoader/Preferences/KeyPunctPrefs.plist`
- 偏好域：`com.wm0104.keypunct.preferences`，键名 `enabled`（bool，缺省 = 开）；面板改动后发 Darwin 通知 `com.wm0104.keypunct/changed`

## 转换表（只换这一个字符）

| 中文 | 英文 | 中文 | 英文 |
| --- | --- | --- | --- |
| ， U+FF0C | `,` | “ U+201C | `"` |
| 。 U+3002 | 保持原样 | ” U+201D | `"` |
| ？ U+FF1F | `?` | ‘ U+2018 | `'` |
| ！ U+FF01 | `!` | ’ U+2019 | `'` |
| ： U+FF1A | `:` | （ U+FF08 | `(` |
| ； U+FF1B | `;` | ） U+FF09 | `)` |
| 、 U+3001 | 保持原样 | 【 U+3010 / 】 U+3011 | `[` / `]` |
| … U+2026 | `...` | 《 U+300A / 》 U+300B | `<` / `>` |
| — U+2014 | `--` | ～ U+FF5E | `~` |

`·` 以及没有英文等价物的字符原样保留。`——`（两个 U+2014）整串都能映射，会变成 `--`。

## 实测记录

- 0.1.0：11 个钩子装上，但引号仍输出中文——缺输出层。
- 0.1.1：加输出层钩子 + 码位日志，确认 `"` 键传入 `0022 0022`、智能标点改写成 `201C 201C`。
- 0.1.2：整串映射规则生效。备忘录读回文本为 `键盘测试"⏎""`（ASCII 引号），`：` 键日志 `： -> :`、输出 `003A`。

## 代码结构

`Sources/Tweak.m`：构造器装钩子 + 转换逻辑。`Prefs/KeyPunctPrefsRootListController.m`：设置面板。

只对“长度 1–4、且**每个**字符都在表里、当前输入法是 `zh_Hans-Pinyin*`、总开关为开、且不处于候选/听写插入过程”的文本做替换。整串全可映射才换的原因：中文键盘的引号/括号键一次会插入成对标点（实测 `"` 键传入 `0022 0022`，智能标点再改写成 `201C 201C`），只认长度 1 会让这些键失效；而候选词里必然含汉字或非表内字符，因此整串规则不会误伤候选。

### 挂钩点（本机 iOS 16.3 实测 `UIKeyboardImpl` 没有 `-insertText:`）

用 `icli probe` 调 `-[NSObject _methodDescription]` 查到的真实方法，四个插入点都装：

- `-[UIKeyboardImpl handleKeyWithString:forKeyEvent:executionContext:]` — `v40@0:8@16@24@32`
- `-[UIKeyboardImpl insertText:withAlternativePredictions:]` — `v32@0:8@16@24`
- `-[UIKeyboardImpl insertTextIfShould:]` — `B24@0:8@16`
- `-[UIKeyboardImpl updateKeyboardOutput:withInputForSmartPunctuation:keyboardConfiguration:]` — `v40@0:8@16@24@32`

**最后一个是关键**。实测日志显示：中文键盘里 `"`、`,` 这类键传给键盘的是**半角**字符，`TISmartPunctuationController` 在 `updateKeyboardOutput:` 里把它们改写成全角 `““`/`””`/`，`。只在前面几层转换会被它改回去，所以输出层必须再收口一次（改 `output` 的 `insertionText`，KVC 写入）。

每个钩子安装前比对 `method_getTypeEncoding`，不一致就跳过并记日志（`KeyPunctInstall … skipped`），不硬套签名。

候选/听写抑制（进入期间 `KeyPunctNonKeyDepth > 0`，期间不做转换）：`acceptCandidate:`、`acceptCandidate:forInput:`、`acceptCurrentCandidate`、`acceptFirstCandidate`、`acceptAutocorrection`、`candidateListAcceptCandidate:`、`handleAcceptedCandidate:executionContext:`、`insertDictationResult:`。

输入法判断：`UIKeyboardInputModeController.sharedInputModeController.currentInputMode` 的 `identifier` 以 `zh_Hans-Pinyin` 开头（26 键为 `zh_Hans-Pinyin`，九宫格为 `zh_Hans-Pinyin@sw=Pinyin-Simplified;hw=Automatic`）。

## 滑动移动光标（已在 0.3.0 移除）

0.2.x 曾自带一套「键盘上任意位置滑动移光标」，因用户已装 SwipeExtenderX（`com.qiop1379.swipeextenderx`，实际文件 `Weed.dylib`，闭源）提供同样能力，且无源码无法合并，**0.3.0 起整段删除**，设置面板也不再有相关项。若以后要重新加回：`UIKeyboardDidShowNotification` → `[UIKeyboardImpl sharedInstance].activeLayout` 挂 `UIPanGestureRecognizer`，横向 `moveCursorByAmount:`，纵向 `UITextInput` 行移动；注意 `setRenderConfig:` 被 `UIKeyboardLayoutStar` 覆盖，挂父类不生效。

## 词库联想（已移除）

曾尝试把 rime-ice 词表接进候选栏：词库读取、前缀二分查表、往系统候选集里插词都验证成功（日志 `KeyPunctDict zhongguob -> 4 added`），但候选栏始终不显示。
试过 `-[UIKeyboardImpl setCandidates:]`、`updateCandidateDisplayAsyncWithCandidateSet:`、`inputManagerDidGenerateCandidatesForRequest:resultSet:`、`UIKeyboardCandidateController` 与 `TUICandidateView` 的 `setCandidateResultSet:`，以及在 `kbd`/`KeyboardUIService` 里挂 `TIKeyboardInputManagerPinyin` 的 `wordSearchEngineDidFindCandidates:`（该进程未加载本包 / 方法未触发）。
结论：候选栏不是读我们改过的那份集合，此路在可安全触及的层面上走不通，代码已整段删除，只保留标点转换。

## 构建

```
apelin_project_build configuration=release
```
产物：`com.wm0104.keypunct_<version>_iphoneos-arm64e.deb`（roothide，arm64e）。rootless 另建一次（arm64 + arm64e）。

安装：`apelin_package_install`（用 build 返回的 artifact id + digest）。装完要**重启 App**（不是 respring）才会加载新 dylib——键盘跑在 App 进程里。

## 实测步骤

1. 装包，`icli app kill --force com.apple.mobilenotes`，再启动备忘录。
2. 抓加载日志（一条 shell 调用里完成，避免焦点被抢）：
   ```
   icli app kill --force com.apple.mobilenotes >/dev/null 2>&1
   (sleep 1; icli app launch com.apple.mobilenotes >/dev/null 2>&1) &
   icli log syslog --seconds 7 --process MobileNotes --subsystem com.wm0104.keypunct --max-lines 60
   ```
   应看到 `ApelinLoaded <buildID> in MobileNotes` 和 11 行 `KeyPunctInstall … hooked`。任何一行是 `encoding … skipped` 或 `missing` 就说明该固件的签名对不上，需要重新查。
3. 备忘录里切简体拼音（26 键 / 九宫格各一次），点 `，。？！：；、` 等键，读回文本框确认是 `, . ? ! : ;`。
4. 点候选词（如“《三体》”类含标点的候选）确认整词原样。
5. 切英文键盘、第三方键盘，确认不受影响。
6. 设置 ▸ KeyPunct 关掉总开关，确认恢复中文标点（1 秒内生效）。

调试：转换成功的每一笔都会打一行 `KeyPunct key/insert/insertIfShould … -> …`（subsystem `com.wm0104.keypunct`）。日志没有历史，要在点键的同时用 `apelin_log_read` 或 `icli log syslog --seconds N` 监听。

## 已知未验证

- `，。？！；、【】《》…～` 这些键逐个点按后的结果（只实测了 `"` `'` `：` `()` `[]` 与普通字母）
- 九宫格布局下的表现
- 长按“，。”弹出的标点选择器（弹窗里选出来的字符也走同一插入路径，预期同样被转换）
- 微信等自绘输入框、第三方键盘内的自定义标点行为
- 关掉总开关后是否立即恢复中文标点（开关面板本身也还没在设置里点过）

## 工具目录（不进包）

`tools/` 是开发期用的运行时探查脚本（`icli probe tools/probe.js`）和自签名小工具，不参与构建（`sources` 只收 `Sources/*.m`、`Prefs/*.m`）。本机 AMFI 要求 CMS 签名，`ldid` 签的可执行文件会被 `Killed: 9`，所以探查改用 `icli probe`，不要指望本地编译的小程序能跑。
