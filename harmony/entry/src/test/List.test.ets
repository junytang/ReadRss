import parserTest from './Parser.test';
import modelTest from './Model.test';
import storeTest from './Store.test';
import utilityTest from './Utility.test';
import progressTest from './Progress.test';
import pagingTest from './Paging.test';
import statusIntegrationTest from './StatusIntegration.test';
import repositoryTest from './Repository.test';
import syncFactoryTest from './SyncFactory.test';
import serviceTest from './Service.test';
import converterTest from './Converter.test';
import privateApiTest from './PrivateApi.test';
import networkTest from './Network.test';
import databaseTest from './Database.test';
import settingsStoreTest from './SettingsStore.test';
import gReaderTokenStoreTest from './GReaderTokenStore.test';
import miscModulesTest from './MiscModules.test';
import accountRepositoryTest from './AccountRepository.test';

export default function testsuite(): void {
  parserTest();
  modelTest();
  storeTest();
  utilityTest();
  progressTest();
  pagingTest();
  statusIntegrationTest();
  repositoryTest();
  syncFactoryTest();
  serviceTest();
  converterTest();
  privateApiTest();
  networkTest();
  databaseTest();
  settingsStoreTest();
  gReaderTokenStoreTest();
  miscModulesTest();
  accountRepositoryTest();
}
