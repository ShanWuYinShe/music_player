import { taskpool } from '@kit.ArkTS';
import { Id3Tag, parseId3 } from './Id3ParserCore';

export { Id3Tag, parseId3 } from './Id3ParserCore';

/** taskpool 任务入口：标签读取（最大 5MB）与帧解析整体移出主线程 */
@Concurrent
function parseId3Concurrent(filePath: string): Id3Tag {
  return parseId3(filePath);
}

/**
 * 异步解析 ID3：经 taskpool 在子线程执行，批量导入多首 mp3 时不再阻塞
 * 主线程。任务调度失败（如环境不支持）回退主线程同步解析；解析本身
 * 全程捕获异常返回空字段，不会 reject。
 */
export async function parseId3Async(filePath: string): Promise<Id3Tag> {
  try {
    const task = new taskpool.Task(parseId3Concurrent, filePath);
    return await taskpool.execute(task) as Id3Tag;
  } catch (err) {
    return parseId3(filePath);
  }
}
