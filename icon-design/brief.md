# Icon brief: Aster
Assumptions: 线条组合、菜单栏只要核心线架、网速可开关且勿锁 72pt——仍有效。上一版 Board 更贴无边记，**不够贴代理**。本版每个概念必须同时过两关：功能（出口 / 选路 / 另一边的网络）和寓意（通达、平安、指引，不要盾与锁那种戒备）。无边记只保留「少、静、精致」，不再当主隐喻。

Product: 把本机流量送到你选定的出口  ·  Audience: 要轻、要原生的 macOS 用户  ·  Category neighbors: 地球仪、盾、锁、火箭、猫、闪电、现用六角星

## Fit
Aster 实际在做三件事：选一条路、从门口出去、外面换成另一重身份（出口 IP）。图标应让人感到**通达**，不是设防。

| 概念 | 功能 | 寓意 |
| --- | --- | --- |
| Moon gate | 门洞 = 出口；门外另一番天地 = 代理身份 | 月洞门：圆满、通达、洞天 |
| Lantern | 看清该走哪条夜路 = 选节点 / 看延迟 | 灯：指引、平安、灯火不灭 |
| Bridge | 此岸本机、彼岸出口 | 桥：沟通、到达、鹊桥 |
| Aster | 选定一颗星 = 选定节点（弱） | 紫菀 / 星途：盼望、定向 |
| Board | 编排策略（弱，像编辑器） | 画板：开始，偏工具不偏祝福 |

## Language
- Dock：发光的场（青到紫）、干净的叠圆、一笔草书 AS（起笔长横、圆润折成 A、再弯成 S）。线是冷白，折角全圆。
- 菜单栏 = 同一笔，template 单色。

## Surfaces
- 菜单栏：template、紧裁、≤ 16 px 宽，能瘦则瘦。
- Dock：同一线架，浅场 + 至多一处点缀色。
- 网速：邻接文字，核心右侧 2–3 px。

## Concepts
### 1. Moon + wave  (axis: none)
Depicts: a phase moon (not a full circle) with one wave threading it
Metaphor: 阴晴圆缺 = 出口会变；浪 = 流量穿过去。
Gestalt device: occlusion / continuity (wave behind then in front)
Line combo: 月相剪影（盈/缺，两弧相切）+ 一根正弦浪。浪用分段色近似渐变（金→青），禁止正圆、禁止单色平涂浪。
16px risk: 太缺像香蕉/C；太盈又回到正圆；分段色在 16px 并成一块。
Distinct from: 地球仪、录音键、Wi-Fi。
Not a UI glyph: 核过 public/globe、wifi、record。
Fit: 功能强（穿过去）· 寓意好（月相、通达）。

### 2. Lantern  (axis: vertical)
Depicts: a lantern
Metaphor: 夜路一盏灯；策略组和延迟是为了看清走哪条。
Gestalt device: similarity-break
Line combo: 提梁弧 + 灯身框 + 一条横档。菜单栏可去掉提梁。
16px risk: 像瓶子或电池。
Distinct from: 闪电、火箭、铃铛。
Not a UI glyph: 核过 battery、bell。
Fit: 功能中（指引选路）· 寓意好（平安灯火）。状态项最瘦。

### 3. Bridge  (axis: vertical)
Depicts: a bridge
Metaphor: 此岸到彼岸；本机连上选定节点。
Gestalt device: continuity
Line combo: 一条拱弧 + 两侧极短桥墩。不要栏杆。
16px risk: 无墩变成 smile，墩一长超过 16 px 宽。
Distinct from: 盾、隧道圆。
Not a UI glyph: 核过 share 节点图、play。
Fit: 功能强（连接）· 寓意好（到达）。

### 4. Aster  (axis: vertical)
Depicts: an aster
Metaphor: 名字；众星里选定一颗，像节点池里选定一个出口。
Gestalt device: similarity-break
Line combo: 小环 + 五或六根等长短辐，辐不碰环。禁止星形折线。
16px risk: 并成齿轮或收藏星。
Distinct from: 现用六角星、地球仪。
Not a UI glyph: 核过 gear、star、sun。
Fit: 功能弱偏名 · 寓意好（星途）。只作备选。

### 5. Board  (axis: vertical)
Depicts: a board
Metaphor: 编排策略的画板。更像无边记，不像「出门」。
Gestalt device: closure
Line combo: 竖向开口圆角框。禁止双框。
16px risk: checkbox / 窗口框。
Distinct from: 地球仪、盾。
Not a UI glyph: 核过 checkbox、app window、focus brackets。
Fit: 功能弱 · 气质贴无边记。降为纪念方案。

## Palette
Dock：青 `#6EB8C8` → 紫 `#4A3A78`；玻璃月浅紫白；线冷白 `#F6F3FF`。
菜单栏：template 单色，同一笔。

## Recommendation
已定稿：**40-caoshu-warm**（Dock）+ **41-menubar-warm**（状态栏）。
正式文件：`icon-design/icon.svg`、`icon-design/menubar.svg`、`assets/Aster.icns`。
