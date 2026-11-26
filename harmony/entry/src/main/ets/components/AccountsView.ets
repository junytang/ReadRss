import { Account, accountTypeName } from '../account/AccountModels';
import { accountRepository } from '../account/AccountRepository';
import { goBack, openAccountEditor } from '../common/NavigationService';
import { FontManager } from '../common/FontManager';
import { ToastUtil } from '../common/ToastUtil';

/** Account list: switch, edit, add and remove accounts. */
@Component
export struct AccountsView {
  @StorageProp('fontScale') uiFontScale: number = 1;
  // Scale fixed UI font sizes with the system font size setting.
  private fs(size: number): number { return size * this.uiFontScale; }

  @StorageLink('darkMode') darkMode: boolean = false;
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('systemFontFamily') systemFontFamily: string = 'sans-serif';
  @StorageProp('topInset') topInset: number = 0;
  @StorageLink('activeAccountId') activeAccountId: string = '1';
  // The editor bumps this tick after a save. onShown is not reliable when
  // returning from another destination, so watch the tick to reload the list.
  @StorageProp('accountSwitchTick') @Watch('load') accountSwitchTick: number = 0;
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
    ToastUtil.show(this.getUIContext(), `已切换到 ${account.name}`);
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
      await accountRepository.remove(account.id);
      await this.load();
    } catch (error) {
      ToastUtil.show(this.getUIContext(), (error as Error).message);
    }
  }


  private appFont(): string {
    // Reading the tick here makes font changes trigger a component rebuild.
    return this.fontDataTick >= 0
      ? FontManager.familyFor(this.systemFontFamily) : 'sans-serif';
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
            .fontSize(this.fs(19))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textColor())
          Blank()
          // Same nav-bar icon button style/size used on the other pages.
          Button() {
            Image($r('app.media.ic_add'))
              .width(19)
              .height(19)
              .fillColor('#1A1C1E')
          }
          .type(ButtonType.Circle)
          .width(38)
          .height(38)
          .backgroundColor(Color.White)
          .onClick(() => openAccountEditor(''))
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 14, bottom: 20 })

        if (this.accounts.length === 0 && !this.isLoading) {
          Text('暂无账号').fontFamily(this.appFont()).fontSize(this.fs(15)).fontColor(this.secondaryColor())
        } else {
          List() {
            ForEach(this.accounts, (account: Account) => {
              ListItem() {
                Row() {
                  Column() {
                    Row() {
                      Text(account.name).fontFamily(this.appFont())
                        .fontSize(this.fs(16))
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.textColor())
                      if (this.activeAccountId === account.id) {
                        Text('当前').fontFamily(this.appFont())
                          .fontSize(this.fs(11))
                          .fontColor(Color.White)
                          .backgroundColor('#2663D6')
                          .borderRadius(8)
                          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                          .margin({ left: 8 })
                      }
                    }
                    Text(accountTypeName(account.type)).fontFamily(this.appFont())
                      .fontSize(this.fs(12))
                      .fontColor(this.secondaryColor())
                      .margin({ top: 5 })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  Row() {
                    // Same 38vp circle + 19vp icon as the navigation bars.
                    Button() {
                      Image($r('sys.media.ohos_ic_public_edit'))
                        .width(19)
                        .height(19)
                        .fillColor('#1A1C1E')
                    }
                    .type(ButtonType.Circle)
                    .width(38)
                    .height(38)
                    .backgroundColor(Color.White)
                    .onClick(() => openAccountEditor(account.id))

                    if (this.accounts.length > 1) {
                      Button() {
                        Image($r('app.media.ic_delete'))
                          .width(19)
                          .height(19)
                          .fillColor('#D93025')
                      }
                      .type(ButtonType.Circle)
                      .width(38)
                      .height(38)
                      // Space the destructive button away from edit.
                      .margin({ left: 16 })
                      .backgroundColor(Color.White)
                      .onClick(() => this.confirmDelete(account))
                    }
                  }
                }
                .width('100%')
                .padding({ left: 16, right: 12, top: 14, bottom: 14 })
                .backgroundColor(this.surfaceColor())
              }
              .onClick(() => this.switchTo(account))
            // Include the name in the key: editing only a name keeps the id
            // unchanged, and ArkUI reuses the ListItem without re-rendering its
            // Text unless the key changes. Exiting/re-entering rebuilt it, which
            // is why the new name appeared only then.
            }, (account: Account) => `${account.id}|${account.name}`)
          }
          .width('100%')
          .layoutWeight(1)
          .divider({ strokeWidth: 1, color: this.darkMode ? '#2A2D31' : '#ECEFF2' })
        }

        // Text('本地账号直接抓取 RSS；Fever 与 Google Reader / FreshRSS 通过远程服务同步。').fontFamily(this.appFont())
        Text('Fever 与 Google Reader / FreshRSS 通过远程服务同步。').fontFamily(this.appFont())
          .fontSize(this.fs(12))
          .fontColor(this.secondaryColor())
          .padding(16)

        if (this.pendingDelete) {
          Column() {
            Column() {
              Text('删除账号').fontFamily(this.appFont())
                .fontSize(this.fs(18))
                .fontWeight(FontWeight.Medium)
                .fontColor(this.textColor())
              // Text(`确定删除「${this.pendingDelete.name}」及其本地数据吗？`).fontFamily(this.appFont())
              Text(`确定删除「${this.pendingDelete.name}」吗？`).fontFamily(this.appFont())
                .fontSize(this.fs(14))
                .fontColor(this.secondaryColor())
                .margin({ top: 12 })
              Row() {
                Text('取消').fontFamily(this.appFont())
                  .fontSize(this.fs(15))
                  .fontColor(this.secondaryColor())
                  .layoutWeight(1)
                  .textAlign(TextAlign.Center)
                  .onClick(() => { this.pendingDelete = undefined; })
                Text('删除').fontFamily(this.appFont())
                  .fontSize(this.fs(15))
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
