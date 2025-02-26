#include "oops/runs/Run.h"
#include "oops/test/base/StateSetMPITest.h"
#include "fv3jedi/Utilities/Traits.h"
#include "test/TestEnvironment.h"
/*
int main(int argc, char ** argv) {
    oops::Run run(argc, argv);
    const eckit::Configuration & config = test::TestEnvironment::config();
//    std::cout << "in statesetMPItest, config is " << config << std::endl;
    oops::test::StateSetMPITest<fv3jedi::Traits> test(config);
    return run.execute(test);
}
*/
int main(int argc, char ** argv) {
  oops::Run run(argc, argv);
  eckit::LocalConfiguration config;
  
  // Set up DA geometry configuration (based on letkf-inline-c48.yaml)
  config.set("da geometry.fms initialization.namelist filename", "Data/ModelRunDirs/c48_001/input.nml");
  config.set("da geometry.fms initialization.field table filename", "Data/ModelRunDirs/UFS_warmstart_1/field_table");
  config.set("da geometry.akbk", "Data/fv3files/akbk127.nc4");
  config.set("da geometry.npx", 49);
  config.set("da geometry.npy", 49);
  config.set("da geometry.npz", 127);
  config.set("da geometry.member_number", 0);
  config.set("da geometry.layout", std::vector<int>{1, 2});
  config.set("da geometry.field metadata override", "Data/fieldmetadata/ufs.yaml");

  // Set up FC geometry configuration (based on forecast_ufs_1.yaml)
  config.set("fc geometry.fms initialization.namelist filename", "Data/ModelRunDirs/UFS_warmstart_1/input.nml");
  config.set("fc geometry.fms initialization.field table filename", "Data/ModelRunDirs/UFS_warmstart_1/field_table");
  config.set("fc geometry.akbk", "Data/fv3files/akbk127.nc4");
  config.set("fc geometry.layout", std::vector<int>{1, 1});
  config.set("fc geometry.io_layout", std::vector<int>{1, 1});
  config.set("fc geometry.npx", 49);
  config.set("fc geometry.npy", 49);
  config.set("fc geometry.npz", 127);
  config.set("fc geometry.ntiles", 6);
  config.set("fc geometry.member_number", 1);
  config.set("fc geometry.field metadata override", "Data/fieldmetadata/ufs.yaml");

  test::TestEnvironment::getInstance().setup(config);
  oops::StateSetMPITest<fv3jedi::Traits> test(config);
  return run.execute(test);
}
