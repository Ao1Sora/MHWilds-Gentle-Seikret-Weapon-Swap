# Gentle Seikret Weapon Swap v1.2.0

《怪物猎人：荒野》REFramework Lua 模组。

## 功能

在玩家位于地面且处于拔刀状态时，使用游戏原版“召唤鹭鹰龙并切换武器”快捷键：

1. 鹭鹰龙仍会正常响应召唤并跑向玩家。
2. 鹭鹰龙抵达后，玩家不会自动骑乘。
3. 玩家在地面切换至备用武器。
4. 新武器直接进入拔刀待机，不播放额外拔刀动作。

若按键时鹭鹰龙已经处于交互范围内，则跳过不再需要的原版召唤/骑乘链，直接执行上述地面切换流程，避免等待和二次原版切换。

以下行为保持原版：

- 已经骑乘鹭鹰龙时的换武器流程。
- 普通召唤鹭鹰龙。

地面收刀自由态由 `Keep sheathed ground behavior vanilla` 控制：

- 勾选（默认）：召唤并换武器使用原版流程。
- 不勾选：与拔刀状态一样等待鹭鹰龙并打断骑乘，在地面换武器；完成后仍保持收刀自由态。

## 安装

需要 REFramework Nightly。

将压缩包中的 `reframework` 文件夹解压到包含
`MonsterHunterWilds.exe` 的游戏目录；也可以通过 Fluffy Mod Manager 安装。

更新旧版本后，请在 REFramework 中执行一次 `Reset Scripts`，或重新启动游戏。

## 使用

模组加载后会出现在 REFramework 的 `Script Generated UI` 中。界面只提供：

- `Enabled`：启用或停用模组。
- `Keep sheathed ground behavior vanilla`：勾选时收刀自由态保持原版；取消勾选时由模组接管。
- `Debug logging`：默认关闭；打开后将完整动作链写入本地日志，供故障检查。
- `State`：当前处理阶段。
- `Last result`：上一次处理结果。

无需配置独立快捷键，继续使用游戏原版快捷键即可。

## 动作时序

动作衔接全部依据本地玩家的 `HunterCharacter.update` 更新帧，不使用系统时间：

- 取消骑乘动作后等待 1 帧。
- 若坐骑已在身边且原版后续骑乘链完全没有启动，等待 300 个猎人更新帧后才启用地面切换回退；正常流程不会提前触发回退。
- 主武器和备用武器对象连续稳定 2 帧后执行切换。
- 切换调用失败时每 3 帧重试。
- 确认切换后的下一帧请求拔刀待机，并逐帧确认拔刀状态。
- 完成后安静保持 45 个猎人更新帧的骑乘保护，再确认最终拔刀/收刀状态；保护期间不会逐帧重复请求拔刀动作。
- 鹭鹰龙等待及整个请求的最长保护时间为 2000 个猎人更新帧。

## 兼容性与限制

- 当前仅建议在单人游戏中使用，多人同步尚未验证。
- 其他同时修改鹭鹰龙骑乘、玩家动作状态或武器切换的 Lua 模组可能产生冲突。
- 游戏大型更新后如果界面显示不支持当前版本，请停用模组并等待适配。

## 故障排查

如果没有触发，请确认：

1. 使用的是“召唤并切换武器”，而不是普通召唤；测试收刀自由态时需取消勾选
   `Keep sheathed ground behavior vanilla`。
2. 两套武器均已在营地配置。
3. REFramework 已成功加载 `Gentle Seikret Weapon Swap v1.2.0`。

默认只记录正常的加载信息以及真正的错误。需要检查完整流程时，打开
`Debug logging` 并复现一次；judge、CallType、骑乘拦截、换武器和恢复拔刀状态等事件
会写入游戏目录中的 `re2_framework_log.txt`。关闭后不会继续写入这些详细事件，并会
立即清空模组内存中的调试计数和 judge 历史。共享日志文件本身不会被删除，因为其中
还包含 REFramework 与其他模组的内容。

## 卸载

删除：

`reframework/autorun/GentleSeikretWeaponSwap.lua`

可选配置文件：

`reframework/data/GentleSeikretWeaponSwap.json`

## 致谢

实现过程中参考了 REFramework 文档，以及 HudController、Weapon Swapper 的公开源码。
本模组为独立实现，不包含其他模组的文件。
