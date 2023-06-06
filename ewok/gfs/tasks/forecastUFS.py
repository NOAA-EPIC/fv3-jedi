# (C) Copyright 2020-2021 UCAR
#
# This software is licensed under the terms of the Apache Licence Version 2.0
# which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.

import os
import yamltools
import ewok.tasks.forecast as generic


class forecastUFS(generic.forecast):

    def setup(self, config, execs, fix, ic):

        # Get generic defaults
        generic.forecast.setup(self, config, execs, fix, ic)

        self.RUNTIME_ENV['COSTFUNCTION'] = config['cost_function']
        self.RUNTIME_ENV['INPUTDIR'] = os.path.join(self.workdir['wdir'], 'INPUT')
        self.RUNTIME_ENV['RESTARTDIR'] = os.path.join(self.workdir['wdir'], 'RESTART')
        self.RUNTIME_ENV['PREFIX'] = '{{ufs_current_cycle}}'

        # Use UFS specific script
        self.command = os.path.join(config['model_path'], "tasks/ufs-run.sh")

