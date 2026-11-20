import { Account, accountTypeName } from '../account/AccountModels';
import { accountRepository } from '../account/AccountRepository';
import { settingsStore } from '../data/SettingsStore';
import { goBack, openAccountEditor } from '../common/NavigationService';
import { FontManager } from '../common/FontManager';

/** Account list: switch, edit, add and remove accounts. */
@Component
export struct AccountsView {
  @StorageLink('darkMode') darkMode: boolean = false;
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('topInset') topInset: number = 0;
  @StorageLink('activeAccountId') activeAccountId: string = '1';
  @State accounts: Account[] = [];
  @State isLoading: boolean = true;
  @State pendingDelete: Account | undefined = undefined;

  private surfaceColor(): string {
    return this.darkMode ? '#1F2226' : '#FFFFFF';
  }

  private textColor(): string {
    return this.darkMode ? '#E8EAED' : '#1A1C1E';
  }

  private secondaryColor(): string {
    return this.darkMode ? '#9AA0A6' : '#5E636A';
  }

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.accounts = await accountRepository.list();
    this.isLoading = false;
  }

  private async switchTo(account: Account): Promise<void> {
    await accountRepository.switchTo(account.id);
    this.activeAccountId = account.id;
    AppStorage.setOrCreate<number>('accountSwitchTick', Date.now());
    this.getUIContext().getPromptAction().showToast({ message: `已切换到 ${account.name}` });
    goBack();
  }

  private confirmDelete(account: Account): void {
    this.pendingDelete = account;
  }

  private async doDelete(): Promise<void> {
    const account: Account | undefined = this.pendingDelete;
    this.pendingDelete = undefined;
    if (!account) {
      return;
    }
    try {
      const removed: boolean = await accountRepository.remove(account.id);
      if (!removed) {
        this.getUIContext().getPromptAction().showToast({ message: '必须至少有一个账户' });
        return;
      }
      await this.load();
      AppStorage.setOrCreate<number>('accountSwitchTick', Date.now());
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: (error as Error).message });
    }
  }


  private appFont(): string {
    // Reading the tick here makes font changes trigger a component rebuild.
    return this.fontDataTick >= 0 ? FontManager.family() : 'sans-serif';
  }

  build() {
    NavDestination() {
      Column() {
        Row() {
          Button() {
            Image($r('app.media.ic_back'))
              .width(19)
              .height(19)
              .fillColor('#1A1C1E')
          }
          .type(ButtonType.Circle)
          .width(38)
          .height(38)
          .backgroundColor(Color.White)
          .margin({ right: 8 })
          .onClick(() => goBack())
          Text('账号管理').fontFamily(this.appFont())
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textColor())
          Blank()
          Text('+ 添加').fontFamily(this.appFont())
            .fontSize(15)
            .fontColor('#2663D6')
            .padding({ right: 8 })
            .onClick(() => openAccountEditor(''))
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 14, bottom: 20 })

        if (this.accounts.length === 0 && !this.isLoading) {
          Text('暂无账号').fontFamily(this.appFont()).fontSize(15).fontColor(this.secondaryColor())
        } else {
          List() {
            ForEach(this.accounts, (account: Account) => {
              ListItem() {
                Row() {
                  Column() {
                    Row() {
                      Text(account.name).fontFamily(this.appFont())
                        .fontSize(16)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.textColor())
                      if (this.activeAccountId === account.id) {
                        Text('当前').fontFamily(this.appFont())
                          .fontSize(11)
                          .fontColor(Color.White)
                          .backgroundColor('#2663D6')
                          .borderRadius(8)
                          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                          .margin({ left: 8 })
                      }
                    }
                    Text(accountTypeName(account.type)).fontFamily(this.appFont())
                      .fontSize(12)
                      .fontColor(this.secondaryColor())
                      .margin({ top: 5 })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  Text('编辑').fontFamily(this.appFont())
                    .fontSize(14)
                    .fontColor('#2663D6')
                    .padding({ left: 10, right: 10 })
                    .onClick(() => openAccountEditor(account.id))
                  if (this.accounts.length > 1) {
                    Text('删除').fontFamily(this.appFont())
                      .fontSize(14)
                      .fontColor('#D93025')
                      .padding({ right: 8 })
                      .onClick(() => this.confirmDelete(account))
                  }
                }
                .width('100%')
                .padding({ left: 16, right: 12, top: 14, bottom: 14 })
                .backgroundColor(this.surfaceColor())
              }
              .onClick(() => this.switchTo(account))
            }, (account: Account) => account.id)
          }
          .width('100%')
          .layoutWeight(1)
          .divider({ strokeWidth: 1, color: this.darkMode ? '#2A2D31' : '#ECEFF2' })
        }

        Text('本地账号直接抓取 RSS；Fever 与 Google Reader / FreshRSS 通过远程服务同步。').fontFamily(this.appFont())
          .fontSize(12)
          .fontColor(this.secondaryColor())
          .padding(16)

        if (this.pendingDelete) {
          Column() {
            Column() {
              Text('删除账号').fontFamily(this.appFont())
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.textColor())
              Text(`确定删除「${this.pendingDelete.name}」及其本地数据吗？`).fontFamily(this.appFont())
                .fontSize(14)
                .fontColor(this.secondaryColor())
                .margin({ top: 12 })
              Row() {
                Text('取消').fontFamily(this.appFont())
                  .fontSize(15)
                  .fontColor(this.secondaryColor())
                  .layoutWeight(1)
                  .textAlign(TextAlign.Center)
                  .onClick(() => { this.pendingDelete = undefined; })
                Text('删除').fontFamily(this.appFont())
                  .fontSize(15)
                  .fontColor('#D93025')
                  .layoutWeight(1)
                  .textAlign(TextAlign.Center)
                  .onClick(() => this.doDelete())
              }
              .width('100%')
              .margin({ top: 24 })
            }
            .width('85%')
            .padding(24)
            .borderRadius(12)
            .backgroundColor(this.surfaceColor())
          }
          .width('100%')
          .height('100%')
          .backgroundColor('#99000000')
          .justifyContent(FlexAlign.Center)
          .position({ x: 0, y: 0 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.darkMode ? '#15171A' : '#F7F8FA')
    }
    .hideTitleBar(true)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .onShown(() => this.load())
  }
}
