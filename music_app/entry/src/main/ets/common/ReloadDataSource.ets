/**
 * 整表替换型 LazyForEach 数据源：包装数组供 LazyForEach 按需创建列表项。
 * 列表总是整体替换（reload），无增量增删场景；可选的 notifyChanged 精确
 * 刷新单行（行内状态变化只重建该行，避免大列表整表重排）。
 */
export class ReloadDataSource<T> implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private list: T[] = [];
  private keyOf: (item: T) => string;

  constructor(keyOf: (item: T) => string) {
    this.keyOf = keyOf;
  }

  reload(list: T[]): void {
    this.list = list;
    this.listeners.forEach((listener) => listener.onDataReloaded());
  }

  /** 精确刷新单个 id 所在行（isPlaying/高亮等行内状态变化） */
  notifyChanged(id: string): void {
    const index = this.list.findIndex((item) => this.keyOf(item) === id);
    if (index < 0) {
      return;
    }
    this.listeners.forEach((listener) => listener.onDataChange(index));
  }

  totalCount(): number {
    return this.list.length;
  }

  getData(index: number): T {
    return this.list[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }
}
