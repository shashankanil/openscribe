/** Also removes listeners whose asynchronous registration completes after unmount. */
export class ListenerScope {
  private disposed = false;
  private listeners: Array<() => void> = [];
  add(registration: Promise<() => void>, onError: (error: unknown) => void) {
    void registration.then(unlisten => {
      if (this.disposed) unlisten(); else this.listeners.push(unlisten);
    }).catch(onError);
  }
  dispose() { this.disposed = true; this.listeners.splice(0).forEach(unlisten => unlisten()); }
}
