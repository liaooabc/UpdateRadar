# 更新雷达（UpdateRadar）

一个常驻 macOS 菜单栏的小工具：扫描本机装的所有 App，找出有新版本的，在菜单栏显示数字角标。
点开是清单，看到「当前版本 → 新版本」，点一下就打开官方下载页，自己决定升不升。

## 怎么用

- 菜单栏右上角出现一个 ⬇ 图标：始终是黑色模板图（系统按菜单栏明暗自动换成白），有更新时可显示数量（如 `14`）。
- 菜单栏图标是自绘的模板图：18pt 的圆圈 + 圆润箭头，跟最初那版一模一样（尺寸别再动，试过 13pt 被否了）。
  只做黑白模板，**不做彩色**（红色那版也试过，同样被否：菜单栏还是原来的样子）。
  见 `main.swift` 的 `makeStatusIcon()`。
- 角标跟着 `updateCount` 走：后台查完会自己刷新，不用等点一下图标。
- **左键**点图标 → 弹出面板。
- **右键**点图标 → 直接弹出菜单：关于 / 检查频率 / 只显示有检测源的 App / 有新版本时通知我 / 菜单栏显示数量 /
  打开数据文件夹 / 打开系统通知设置 / 检查更新（⌘R）/ 退出（⌘Q）。
  实现上用的是「临时把 NSMenu 挂到 statusItem 再 performClick」的标准做法；
  早先用 `menu.popUp(positioning:at:in:)` 手动定位会把菜单第一项裁掉。
- 面板用系统自己的 **NSPopover**（`.transient`，点别处或按 Esc 自己收起）：
  玻璃材质、圆角、窗口阴影、弹出动画全部交给 AppKit，不再自己画。
  早先是自己写的无边框 NSPanel + NSVisualEffectView，踩了两个坑：
  透明窗口系统不给画阴影（`hasShadow` 开不开像素级一模一样），
  玻璃材质按整窗铺、layer 的 `cornerRadius` 裁不住，四角会露出直角边。
  自己补的阴影又会被看成"多出来一块灰板"，所以最后整段换成了系统面板。
  代价：系统面板带一个小三角箭头、并且以图标为中心对齐（不是左上角对齐）。
- 左键面板里：
  - **可更新**：只列出有新版本的 App，点某一行直接打开它的下载页。
    行右侧留 18pt 空白，因为滚动时系统的浮层滚动条会压在右边，胶囊挨太近会显得挤。
    每一行的排版照 App Store 的更新列表来：40pt 图标、13pt 加粗名称、
    版本号 + 发布日期、「更新」蓝色胶囊按钮，下面一行更新说明（超出部分省略）。
    更新说明来自各 App 自己的更新源：App Store 的 `releaseNotes`、
    Sparkle appcast 的 `<description>` 或 `releaseNotesLink`。
  - **其他**：除「有更新」之外的 App 都在这儿，带搜索框。列表按组折叠：
    **已是最新 → 无检测源 → 检测失败 → 已忽略**，每组标题（`▾ 组名 + 数量`）点一下就收起/展开，
    搜索时强制展开（不然搜到的东西会藏在收起的组里）。
    这一页平时不列有更新的 App（它们在「可更新」页签里），
    但**搜索时会把有更新的也一起列出来**——否则搜一个正在等更新的 App 会"查无此 App"。
    已忽略的 App 不再从列表里消失，而是收在最后一组，右键「恢复提醒（不再忽略）」就能加回来。
    已是最新的行右侧写「已是最新版本」（不再用绿色对勾，10.5pt 半粗黑字，别太灰），
    「检测失败」和「已是最新版本」共用 `statusText(_:)` 这一处样式（10.5pt 半粗、主文字色），
    以后不可能再飘；前面配 9pt 琥珀色小三角（沿用最初那版的大小和位置，不加偏移）。
    每一组标题上面有一条更粗更亮的横线，和上一组隔开。
  - 右键某一行：打开下载页 / 在 Finder 中显示 / **这个已经是最新（不再提醒）** / 忽略它（不再提醒）。
    「已忽略」那一组里的行，最后一项换成「恢复提醒（不再忽略）」。
  - 有新版本的行会带上发布/更新时间（如 `1.16.0 → 1.17.0 · 10月18日`），看得出这个更新是不是真的。
  - 右下角齿轮：检查频率（1/6/12/24 小时）、只显示有检测源的 App、有新版本时通知我、
    **菜单栏显示数量**（关掉后菜单栏只剩图标，悬停仍能看到数量）、打开数据文件夹、退出。
- 关掉面板它继续在菜单栏跑，按设定频率自动检查。

### 通知

- 发现新版本时弹一条系统横幅：「3 个 App 有新版本 · WeChat 4.1.15→4.1.20、…」。
- 只在**可更新清单发生变化**时提醒一次，不会每轮检查都弹。
- 点横幅会直接展开菜单栏面板。
- 齿轮菜单里可以关掉通知，或跳到系统通知设置。首次运行系统会问一次是否允许。

## 检测原理（四层，逐层回退）

1. **厂商专用规则**：没有标准更新源的 App，直接读官网页面 / GitHub 上的版本号。目前覆盖：
   - 微信：从官网下载链接 `WeChatMac_4.1.15.dmg` 取版本
   - QQ：官网 dmg 文件名里的稳定版版本号（内测版另算）
   - Obsidian / Motrix / Anki / 洛雪音乐 / UVR：GitHub Releases 最新 tag
   - Chrome：`versionhistory.googleapis.com` 国内不通，改用 Chrome for Testing 的 Stable 版本
   - WPS Office：官网产品页里的版本号
2. **Sparkle appcast**：App 的 `Info.plist` 里有 `SUFeedURL` 就能读它的更新源（本机 34 个 App 有）。
   注意区分营销版本号（`<title>` / `sparkle:shortVersionString`）和内部构建号（`sparkle:version`）——构建号不能拿来和版本号比。
   抓失败时先交给第 4 层兜一次，别急着把行标成「检测失败」。
3. **Mac App Store**：带 `_MASReceipt` 的 App 用 `itunes.apple.com/lookup?bundleId=` 查商店版本。
   lookup 是**分区**的：国区没上架的 App 在 `country=cn` 下返回 `resultCount=0`，会像「不在商店」，
   所以国区查不到时再试一次 `country=us`（只在没命中时才多发一个请求）。实测 Slack：cn=0 / us=1。
4. **Homebrew Cask**（社区维护的版本库，7000+ 个 Mac App，含大量没有 appcast 的商业软件）：
   覆盖 Sketch、Spotify、Telegram、Raycast、Notion、Blender、Zotero、GitHub Desktop、
   Microsoft Office 五件套、Topaz 三件套、Canva、哔哩哔哩、DropDMG、UPDF 等。

   实现上不下载那份 18 MB 的完整索引：`Resources/cask-map.json`（约 0.7 MB）随 App 发布，
   里面是「.app 文件名 / bundle id → cask 名」的映射；运行时只按需拉单个 cask 的约 1 KB JSON，
   结果按 12 小时缓存到 `~/Library/Application Support/UpdateRadar/cask-cache.json`。
   映射表用 `python3 tools/make_cask_map.py` 重新生成（想覆盖更多 App 时隔一两个月跑一次）。

   cask 这条路有两个坑，代码里都堵上了：
   - **同名不同版**：Telegram.app 可能是 `com.tdesktop.Telegram`（Telegram Desktop）也可能是
     `ru.keepcoder.Telegram`（原生版），版本号体系完全不同。所以「只按文件名对上的」匹配，
     还要用 cask 的 `uninstall` 段里登记的 bundle id 复核，对不上就判为另一个 App。
   - **构建号不是版本号**：Office 的 cask 版本写作 `16.114.26101123`，本机标注 `16.114`，
     直接比会天天报「有新版本」。所以「多出来的几段都是 6 位以上纯数字」时按已最新处理。

都没有的 App 记为「无检测源」，仍然列出来但不会打扰你。

网络层有两个容错：请求失败会重试一次；`raw.githubusercontent.com` 的源会走 jsDelivr 镜像兜底（国内常被墙）。

**GitHub API 会限流**：未认证只有 60 次/小时/IP，同一个 Wi-Fi 下几台 Mac 共用配额。
撞墙时 GitHub 返回 `403 + X-RateLimit-Remaining: 0`（和「仓库没了」的 404 不是一回事），
所以现在会明确说「GitHub 接口限流」，而不是笼统的「检测失败」。

**「检测失败」会说原因**：行里直接显示一句短的（如「更新源没有响应」「GitHub 接口限流」），
鼠标停在「⚠ 检测失败」上看完整说明。

## 资源占用（实测）

| 场景 | 内存（活动监视器口径 phys_footprint） | CPU |
|---|---|---|
| 常驻后台，检查已完成 | ~46 MB | 0.0% |
| 单次检查进行中 | 峰值 ~77 MB，结束后回落 | 短暂 10% 左右 |
| 面板打开 | ~50 MB | 0.0% |

磁盘：App 本身 3.6 MB（2.2 MB 图标资源 + 0.7 MB cask 名称表），数据文件 28 KB + cask 缓存。
线程 3 个，句柄 60 上下。跑满两轮检查后内存不再上涨，没有泄漏。

## 性能

列表滚动做了三件事，缺一个都会明显卡：

1. **图标缓存**（`IconCache`）：`NSWorkspace.icon(forFile:)` 每次调用都会问 LaunchServices，
   原先每行每次重绘都要问一次；现在按路径缓存。
2. **悬停状态按行隔离**（`HoverStore` / `HoverBox`）：原先鼠标掠过任一行都会让整个
   `ContentView` 重绘；现在每行一个独立的小 ObservableObject，只重绘那一行。
3. **LazyVStack**：只实例化可见的行，138 个 App 不会一次性建视图。
   另去掉每行的 `.help()` tooltip（滚动时也会掉帧）。

## 外观

- 面板内的分段按钮、搜索框、「去更新」都用胶囊圆角（`Capsule()`），跟面板本身的圆角
  （macOS 26 的 NSPopover ≈16pt）保持同一量级。
- 面板就是系统的 **NSPopover**（`.transient`）：材质、圆角、阴影、动画都由 AppKit 负责，
  点桌面 / 别的 App / 按 Esc 都会自动收起。
  代价是它带一个指向菜单栏图标的小三角，而且以图标为中心对齐（不能只贴左边）。
- 面板不铺任何不透明底色，直接透出 NSPopover 自带的系统材质（macOS 26/27 的液态玻璃），
  背后的桌面和窗口会隐约透出来；文字用语义色，深浅外观自动适配。
- 想在代码里改样式时记住：**不要在页面根视图上加 `background`**，一旦不透明，玻璃就没了。

## 图标

- **设计源文件：`Resources/AppIcon.icon`**（Icon Composer 文档，`icon.json` + `Assets/*.svg`）。
  想改配色/形状，用 Xcode → Open Developer Tool → Icon Composer 打开它改，
  或者直接改 `Assets/*.svg`（纯文本，颜色写在 `stop-color` 里）。
- 构建时 `build.sh` 把它拷到 `build/AppIcon.icon`（actool 只认这个位置），
  再用 `actool` 编成 `Assets.car` + `AppIcon.icns` 塞进 App。
- **四个图层，白天 / 暗夜各一套**（由 `icon.json` 里每层的 `opacity-specializations` 互斥切换）：

  | 图层 | 内容 | 白天 | 暗夜 |
  |---|---|---|---|
  | 3_Arrow | 下载箭头（76px 圆头粗线，竖杆 + 折线箭头） | `#5AB0FF → #007AFF` | `#7BD0FF → #0A84FF` |
  | 2_Ring | 外圈光环（r≈354，132px 环宽） | `#FFFFFF → #B9C2C9` | `#3A4046 → #15181B` |
  | 1_Plate | 中间灰色圆盘（r=288，径向渐变） | `#7C8288 → #4E5459` | `#2E3338 → #14171A` |
  | 0_Bg | 底板（**在下面那组**，带 0.3 半透明 + 阴影） | `#FFFFFF → #EAEFF2` | `#141414 → #000` |

  前景组带 `shadow: 0.5`，底板组带 `translucency: 0.3 + shadow: 0.3` —— 所以图标有
  分层悬浮的立体感，不是一张平面图。`Assets/` 里还留着几个旧版绿色图层
  （`01-arcs-*`、`02-arrow-*`、`03-base-*`），`icon.json` 没引用它们，actool 会忽略。
- **关键写法（别再走弯路）**：明暗两套要靠 `opacity-specializations`，不是 `image-name-specializations`。
  一个 group 里放两份图层，各自在对方外观下把不透明度设为 0：

  ```json
  { "image-name" : "03-arrow-day.svg", "name" : "3_Arrow_Day",
    "opacity-specializations" : [ { "appearance" : "dark", "value" : 0.0 } ] }
  { "image-name" : "03-arrow-night.svg", "name" : "3_Arrow_Night",
    "opacity-specializations" : [ { "appearance" : "light", "value" : 0.0 },
                                  { "appearance" : "tinted", "value" : 0.0 } ] }
  ```

  验证办法：`xcrun assetutil --info Assets.car` 里的 `IconGroup`，在
  `NSAppearanceNameAqua` / `NSAppearanceNameDarkAqua` 下各层的 `LayerOpacity` 必须正好 1 / 0 互换。
  渲染预览（六种外观）：
  `"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" Resources/AppIcon.icon --export-image --output-file /tmp/a.png --platform macOS --rendition Dark --width 512 --height 512 --scale 1`
- **分组顺序：`groups[0]` 在上、`groups[1]` 在下**。底板必须放最后一个组，否则会把前景盖成淡色；
  组内则是第一个图层在最前。
- `tinted`（系统「着色」外观）里底板两层都是 0：那块底色交给系统自己的着色玻璃，只留前景图形。
- **踩过的坑（都别再试）**：
  - `image-name-specializations`（图层级指定暗色用哪张图）：`actool` **静默丢弃**，只剩一张。
  - 资源目录（`AppIcon.appiconset`）里的 `appearances: luminosity/dark`：mac 平台同样被丢，10 个尺寸只剩亮的。
  - `actool` 的输出目录**必须是 `mktemp -d` 的临时目录**，直接写进「文稿」下的 `build/` 会报
    `BOMStorageCompact ... rename failed Operation not permitted`，只留个半成品和 `tmp.XXXX`。
  - `actool` 对**别的路径**的 `.icon` 会静默不产出（连错误都没有）；老老实实用 `build/AppIcon.icon`。
  - SVG 的 y 轴在渲染时是反的：`linearGradient` 的 `offset 0` 那端落在图标**底部**，写反渐变方向就颠倒。
  - 线宽别改细：原来的细线在 32px（1024 缩 32 倍）下只剩零点几像素，会断成噪点。

## 数据与自检

- `state.json` 里的检测结果会**随扫描自动清理**：扫不到的 App（已卸载）的结果会被删掉，
  但「忽略它 / 这个已经是最新」这类**你手动做过的决定不会被清**——外接盘拔了、某次扫描抖动，
  那些记录都还在。
- `build.sh` 开头有一段 `-strict-concurrency=complete` 自检，会打印还剩几条并发告警
  （当前 6 条，都是 `Cask` / `IconCache` 里的静态变量，Swift 5 下无害、Swift 6 会变成错误）。
  这个数**不要当成 0**：加锁解决的是运行时竞争，编译器不认账。

## 文件位置

- 源码：`src/`（`Version.swift` 版本比较、`Scanner.swift` 扫描、`Checkers.swift` 检测器与规则表、`Service.swift` 状态与定时、`ContentView.swift` 界面、`main.swift` 菜单栏入口）
- 构建：`./build.sh` → 产出 `build/更新雷达.app` 并做临时签名
- 数据：`~/Library/Application Support/UpdateRadar/state.json`（检测结果缓存 + 设置）

## 发新版（不用懂代码）

双击 **`一键发布.command`** 一次到底：升版本号 → 编译 → 打 DMG → 推源码 → 建 Release → 传安装包。

只想要安装包不发 GitHub，就双击 **`发版.command`**（升版本 + 打包，不发）；只想发已打好的包，双击 **`发布到GitHub.command`**。

**更新说明写在仓库根目录的 `发布说明.md` 里**，发版时原样当作 Release 说明贴上去——想写多短就多短，改完保存即可，不用动脚本。

第一次双击如果提示"无法打开"，右键 → 打开 一次即可（和 App 一个道理）。

## 重新编译

```bash
cd UpdateRadar
./build.sh
rm -rf "/Applications/更新雷达.app"
cp -R "build/更新雷达.app" /Applications/
open "/Applications/更新雷达.app"
```

脚本里固定了 `DEVELOPER_DIR=/Library/Developer/CommandLineTools`，因为这台机器装了 Xcode.app 但没同意许可协议，
直接用会报 license 错误。

## 加一个新的检测规则

编辑 `src/Checkers.swift` 末尾的 `Rules.all`，加一条：

```swift
VendorRule(matches: { $0.bundleId == "com.example.app" }) { app in
    await pageRegex(app: app,
                    page: "https://example.com/download",
                    pattern: #"Example-([0-9]+\.[0-9]+\.[0-9]+)\.dmg"#,
                    downloadPage: "https://example.com/download")
}
```

或 GitHub 发布的用 `githubRepo(app:repo:downloadPage:)`。

## 已知限制

- **Chrome、Telegram、Spotify、Microsoft Office 目前查不了**：它们的版本接口在你这台机器上连不通
  （`versionhistory.googleapis.com`、`telegram.org` 超时），且没有公开的 appcast。
- 少数源会间歇性失败（显示「检测失败」），点右上角刷新重试即可。
- 用 `sparkle:version` 只给构建号、连 `<title>` 都不带版本号的源（如 Keka）无法判断。
- **App Store 应用的版本号可能对不上**：有些开发者发版时只改了商店的营销版本号（列表显示 1.13），
  Mac 包里的 `CFBundleShortVersionString` 还是 1.4，Apple 按构建号判断、认为已是最新，但版本号比较就会误报。
  公开接口拿不到商店包的构建号，所以遇到这种情况请右键该行 →「这个已经是最新（不再提醒）」，
  记下当时的商店版本；商店以后真出更高版本时会自动恢复提醒。
- **Microsoft Office 系列也查不了**：微软只公开 AutoUpdate 程序自己的源，不提供 Word/Excel 各 App
  版本的公开接口；Notion、Sketch、Spotify、Raycast 同样没有可用的公开源。
- 没有开机自启（ad-hoc 签名下做自启容易失效）。
- 临时签名（ad-hoc）：本机运行没问题，拷给别人会提示「无法验证开发者」。

## 换图标后看不到变化？

LaunchServices 会缓存应用图标。换图后执行：

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/更新雷达.app"
touch "/Applications/更新雷达.app"
killall Dock; killall Finder
```

## 调试用环境变量

```bash
UPDATERADAR_SHOW_ON_LAUNCH=1 /Applications/更新雷达.app/Contents/MacOS/UpdateRadar  # 启动即展开面板
UPDATERADAR_TEST_NOTIFY=1  ...                                                     # 6 秒后发一条测试通知
UPDATERADAR_SHOW_MENU=1    ...                                                     # 启动即弹出右键菜单
UPDATERADAR_SHOW_ABOUT=1   ...                                                     # 启动即打开「关于」窗口
UPDATERADAR_FORCE_DARK=1   ...                                                     # 强制深色外观（验证图标用）
UPDATERADAR_FORCE_LIGHT=1  ...                                                     # 强制浅色外观
```
