import {
  Account,
  AccountType,
  CredentialCodec,
  EMPTY_SECURITY_KEY,
  RemoteCredentials,
  accountTypeName,
  defaultAccountFields,
} from '../account/AccountModels';
import { accountRepository } from '../account/AccountRepository';
import { database } from '../data/Database';
import { rssRepository } from '../rss/RssRepository';
import { syncServiceFor } from '../rss/SyncServiceFactory';
import { goBack } from '../common/NavigationService';
import { Logger } from '../common/Logger';
import { FontManager } from '../common/FontManager';

interface TypeChoice {
  type: AccountType;
  label: string;
}

const TYPES: TypeChoice[] = [
  { type: AccountType.LOCAL, label: '本地' },
  { type: AccountType.FEVER, label: 'Fever' },
  { type: AccountType.GOOGLE_READER, label: 'Google Reader' },
  { type: AccountType.FRESH_RSS, label: 'FreshRSS' },
];

/** Add/edit account form with credential validation. */
@Component
export struct AccountEditorView {
  @Prop accountId: string = '';
  @StorageLink('darkMode') darkMode: boolean = false;
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('topInset') topInset: number = 0;
  @State type: AccountType = AccountType.LOCAL;
  @State name: string = '';
  @State serverUrl: string = '';
  @State username: string = '';
  @State password: string = '';
  @State clientCertificateAlias: string = '';
  @State errorMessage: string = '';
  @State isSaving: boolean = false;

  private isNew(): boolean {
    return this.accountId.length === 0;
  }

  private textColor(): string {
    return this.darkMode ? '#E8EAED' : '#1A1C1E';
  }

  private secondaryColor(): string {
    return this.darkMode ? '#9AA0A6' : '#5E636A';
  }

  aboutToAppear(): void {
    if (!this.isNew()) {
      this.load();
    }
  }

  private async load(): Promise<void> {
    const account: Account | undefined = await database.getAccount(this.accountId);
    if (!account) {
      this.errorMessage = '账号不存在';
      return;
    }
    this.type = account.type;
    this.name = account.name;
    if (account.type !== AccountType.LOCAL) {
      const credentials: RemoteCredentials = accountRepository.credentials(account);
      this.serverUrl = credentials.serverUrl;
      this.username = credentials.username;
      this.password = credentials.password;
      this.clientCertificateAlias = credentials.clientCertificateAlias;
    }
  }

  private credentials(): RemoteCredentials {
    let url: string = this.serverUrl;
    if ((this.type === AccountType.GOOGLE_READER || this.type === AccountType.FRESH_RSS)
      && url.length > 0 && !url.endsWith('/')) {
      url += '/';
    }
    return {
      serverUrl: url,
      username: this.username,
      password: this.password,
      clientCertificateAlias: this.clientCertificateAlias,
    };
  }

  private async save(): Promise<void> {
    if (this.isSaving) {
      return;
    }
    const credentials: RemoteCredentials = this.credentials();
    if (this.type !== AccountType.LOCAL) {
      if (credentials.serverUrl.length === 0 || credentials.username.length === 0
        || credentials.password.length === 0) {
        this.errorMessage = '服务器地址、用户名和密码均为必填项';
        return;
      }
    }
    this.isSaving = true;
    this.errorMessage = '';
    try {
      if (this.isNew()) {
        // Android inserts first, then validates, then rolls back on failure.
        const added: Account = await accountRepository.add(this.type, this.name, credentials);
        try {
          const valid: boolean = await syncServiceFor(added).validCredentials(added);
          if (!valid) {
            throw new Error('Unauthorized');
          }
          // Android's doSyncOneTime() only enqueues background work and returns immediately.
          // Do not block the save flow on a potentially long first sync.
          rssRepository.syncAll().catch((error: Error) => {
            Logger.error(`Account initial sync failed: ${error.message}`);
          });
        } catch (error) {
          await accountRepository.remove(added.id);
          throw error as Error;
        }
      } else {
        const account: Account | undefined = await database.getAccount(this.accountId);
        if (!account) {
          throw new Error('账号不存在');
        }
        account.type = this.type;
        account.name = this.name;
        if (this.type === AccountType.LOCAL) {
          account.securityKey = EMPTY_SECURITY_KEY;
        }
        await accountRepository.update(account, this.type === AccountType.LOCAL ? undefined : credentials);
        // Android only clears authorization on edit; it does not re-validate.
        syncServiceFor(account).clearAuthorization();
      }
      AppStorage.setOrCreate<number>('accountSwitchTick', Date.now());
      this.getUIContext().getPromptAction().showToast({ message: '账号已保存' });
      goBack();
    } catch (error) {
      this.errorMessage = (error as Error).message;
    } finally {
      this.isSaving = false;
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
          Text(this.isNew() ? '添加账号' : '编辑账号').fontFamily(this.appFont())
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textColor())
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 14, bottom: 12 })

        Scroll() {
          Column() {
            Text('账号类型').fontFamily(this.appFont()).fontSize(13).fontColor(this.secondaryColor()).alignSelf(ItemAlign.Start)
            Row() {
              ForEach(TYPES, (choice: TypeChoice) => {
                Text(choice.label).fontFamily(this.appFont())
                  .fontSize(13)
                  .fontColor(this.type === choice.type ? Color.White : this.textColor())
                  .backgroundColor(this.type === choice.type ? '#2663D6' : (this.darkMode ? '#1F2226' : '#FFFFFF'))
                  .borderRadius(16)
                  .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                  .margin({ right: 8 })
                  .onClick(() => { this.type = choice.type; })
              })
            }
            .width('100%')
            .margin({ top: 10 })

            Column() {
              Text('名称').fontFamily(this.appFont()).fontSize(13).fontColor(this.secondaryColor()).alignSelf(ItemAlign.Start)
              TextInput({ text: this.name, placeholder: '可选' })
                .width('100%').height(44).margin({ top: 8 }).fontSize(15)
                .backgroundColor(this.darkMode ? '#1F2226' : '#FFFFFF')
                .fontColor(this.textColor())
                .onChange((value: string) => { this.name = value; })
            }
            .width('100%').margin({ top: 16 })

            if (this.type !== AccountType.LOCAL) {
              Column() {
                Text('服务器地址').fontFamily(this.appFont()).fontSize(13).fontColor(this.secondaryColor()).alignSelf(ItemAlign.Start)
                TextInput({
                  text: this.serverUrl,
                  placeholder: this.type === AccountType.FEVER
                    ? 'https://demo.freshrss.org/api/fever.php'
                    : 'https://demo.freshrss.org/api/greader.php',
                })
                  .width('100%').height(44).margin({ top: 8 }).fontSize(15)
                  .backgroundColor(this.darkMode ? '#1F2226' : '#FFFFFF')
                  .fontColor(this.textColor())
                  .onChange((value: string) => { this.serverUrl = value; })
              }
              .width('100%').margin({ top: 16 })

              Column() {
                Text('用户名').fontFamily(this.appFont()).fontSize(13).fontColor(this.secondaryColor()).alignSelf(ItemAlign.Start)
                TextInput({ text: this.username })
                  .width('100%').height(44).margin({ top: 8 }).fontSize(15)
                  .backgroundColor(this.darkMode ? '#1F2226' : '#FFFFFF')
                  .fontColor(this.textColor())
                  .onChange((value: string) => { this.username = value; })
              }
              .width('100%').margin({ top: 16 })

              Column() {
                Text('密码').fontFamily(this.appFont()).fontSize(13).fontColor(this.secondaryColor()).alignSelf(ItemAlign.Start)
                TextInput({ text: this.password })
                  .width('100%').height(44).margin({ top: 8 }).fontSize(15)
                  .type(InputType.Password)
                  .backgroundColor(this.darkMode ? '#1F2226' : '#FFFFFF')
                  .fontColor(this.textColor())
                  .onChange((value: string) => { this.password = value; })
              }
              .width('100%').margin({ top: 16 })

              Column() {
                Text('客户端证书别名（可选）').fontFamily(this.appFont()).fontSize(13).fontColor(this.secondaryColor())
                  .alignSelf(ItemAlign.Start)
                TextInput({ text: this.clientCertificateAlias })
                  .width('100%').height(44).margin({ top: 8 }).fontSize(15)
                  .backgroundColor(this.darkMode ? '#1F2226' : '#FFFFFF')
                  .fontColor(this.textColor())
                  .onChange((value: string) => { this.clientCertificateAlias = value; })
              }
              .width('100%').margin({ top: 16 })
            }

            if (this.errorMessage.length > 0) {
              Text(this.errorMessage).fontFamily(this.appFont())
                .fontSize(13)
                .fontColor('#D93025')
                .margin({ top: 16 })
                .alignSelf(ItemAlign.Start)
            }

            Button(this.isSaving ? '正在验证…' : '保存')
              .width('100%')
              .height(44)
              .margin({ top: 28 })
              .enabled(!this.isSaving)
              .onClick(() => this.save())

            Text('Fever 的 API Key 由用户名与密码自动计算；Google Reader / FreshRSS 使用 ClientLogin + Token 鉴权。').fontFamily(this.appFont())
              .fontSize(12)
              .fontColor(this.secondaryColor())
              .margin({ top: 20 })
          }
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 32 })
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.darkMode ? '#15171A' : '#F7F8FA')
    }
    .hideTitleBar(true)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
