(function () {
  const FMNative = {
    isNative() { return true; },
    async pickImage(opts: { quality?: number; allowEditing?: boolean; source?: 'prompt' | 'camera' | 'photos' } = {}) {
      try {
        throw new Error('FMNative.pickImage is not wired yet');
      } catch (e) {
        return null;
      }
    }
  };
  (window as any).FMNative = (window as any).FMNative || FMNative;

  function dispatch(name: string, detail: any) {
    window.dispatchEvent(new CustomEvent(name, { detail }));
  }
  (window as any).__FMDispatch = (window as any).__FMDispatch || dispatch;
})();