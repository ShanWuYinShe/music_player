# music_app 在线源与缓存

> 本文是 skill `music-app-platform-ui` 的细节补充。在线源的摘要与触发条件在 SKILL.md；改在线源、缓存、收藏融合或播放失败处理时读本文。

## 在线源接口

- 首页一级签「在线」，`OnlineSource.fetchSongs(q)` 拉取 `/songs`（解析纯函数在 `source/OnlineApi.ets`，可 LocalUnit 单测）；在线搜索由 Index 防抖 600ms 触发，列表即服务端返回不做本地二次过滤；本地曲库时长由服务端解析容器元数据返回（durationMs），客户端 prepared 后仍会校准。
- 在线页同时拉 `/providers`（`fetchProviders`）获取网易云登录态（仅用于试听曲不进缓存与播放页「VIP 试听」标注的判定；服务端源状态不进客户端 UI），曲目 `vip` 字段驱动 VIP 徽标与播放页「VIP 试听」标注。
- 播放失败（无版权/网络错误）由 `PlayerController.handlePlaybackFailure` 统一 toast + 自动跳下一首，连续 3 首失败熔断；服务地址设置页持久化，留空回落默认地址（契约见上级 AGENTS.md）。

## SWR 列表缓存

- 成功结果进 OnlineSource 内存缓存（按查询词键控，容量 8，来回切源秒开），默认视图（空查询）同时持久化 `filesDir/online_list_cache.json`（杀进程重开秒开）；进在线页先展示缓存（不再整页 loading）。
- TTL 10 分钟内不发网络、过期静默刷新；下拉刷新/重复点在线标签/重试/改服务地址强制绕过缓存；换 baseUrl 缓存整体失效（纯函数 `isCacheFresh`/`serializeOnlineCache`/`parseOnlineCache` 在 OnlineApi.ets）。

## 收藏/最近跨源融合（口径：喜欢不区分在线离线）

- 在线歌元数据持久化在 `source/OnlineSongStore.ets`（`filesDir/online_songs.json`，纯函数 `serializeOnlineSongStore`/`parseOnlineSongStore` 在 OnlineApi.ets），收藏（`AppStore.toggleFavorite` 唯一入口，PlayerPage ♥ 调用）与播放（`playSongInternal` 内 upsert）时注册。
- 喜欢/最近 Tab 经 `LibraryFilter.FilterOptions.onlineSongs` 补位混排（ALL Tab 不混入；注册表非响应式，靠 favoriteIds/recentIds 的 @Trace 改写触发 @Computed 重算）；`PlayerController.findSong` 第三级兜底注册表（点播收藏在线歌/续播恢复都走这条）；换服务地址时注册表条目流地址按当前生效地址重拼（服务端 id 稳定）。

## 收藏钉住缓存

- 收藏的在线歌同步进 `OnlineCache` pin 集合（不持久化，启动由收藏∩注册表重建），淘汰垫后（纯函数 `evictOrder`：非 pin 最旧在前、pin 垫后、在途跳过；全 pin 超限时 pin 内按 lastAccess 兜底，磁盘 500MB 硬上限不破），未缓存的收藏歌主动排队整曲下载（VIP 未登录试听曲不下载防污染）。
- 下载队列限并发 2（`MAX_ACTIVE_DOWNLOADS`），播放伴随下载与收藏补下载共用，播放下载随切歌中止（代际号）、收藏下载不中止；取消收藏解除 pin（已下音频回归普通 LRU，不删文件）；注册表只留收藏∪最近引用的条目（`retain`），清空曲库时一并清。
- 长按菜单「从曲库删除」对在线歌不显示（`isOnlineId` 判定）。
