import { UIContext } from '@kit.ArkUI';
import { Logger } from './Logger';

/**
 * Show a toast without letting a UI-service failure break the caller.
 * PromptAction.showToast is annotated @throws, so every direct call site needs
 * exception handling; centralising it also keeps the components warning-free.
 */
export class ToastUtil {
  static show(context: UIContext, message: string): void {
    try {
      context.getPromptAction().showToast({ message: message });
    } catch (error) {
      Logger.warn(`Toast unavailable: ${(error as Error).message}`);
    }
  }
}
