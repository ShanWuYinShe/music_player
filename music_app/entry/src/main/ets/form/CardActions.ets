/**
 * 桌面卡片播放控制：message 型 postCardAction 发指令到 FormAbility（经
 * 公共事件转发主进程后台执行，不拉起应用）。call 型真机不送达、router 型
 * 会拉前台，均已踩坑——两卡片统一走此函数，勿在卡片内另写分派。
 */
export function cardPlayAction(component: object, method: string): void {
  postCardAction(component, {
    action: 'message',
    abilityName: 'MusicFormAbility',
    params: { method: method }
  });
}
