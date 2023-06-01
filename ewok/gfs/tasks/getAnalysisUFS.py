# (C) Copyright 2023 UCAR
#
# This software is licensed under the terms of the Apache Licence Version 2.0
# which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.

import os
import ewok.tasks.getAnalysis as generic
import yamltools

class getAnalysisUFS(generic.getAnalysis):

    def setup(self, config, fix):

        # Get generic defaults
        generic.getAnalysis.setup(self, config, fix)

        # Remove extra info in names of files so it is readable by FMS
        self.output['datapath'] = os.path.join(self.output['datapath'], 'INPUT')
        self.output['filename_core'] = 'fv_core.res.nc'
        self.output['filename_trcr'] = 'fv_tracer.res.nc'
        self.output['filename_sfcd'] = 'sfc_data.nc'
        self.output['filename_sfcw'] = 'fv_srf_wnd.res.nc'
        self.output['filename_cplr'] = 'coupler.res'

        # Needed to link static data
        self.RUNTIME_YAML['fcworkdir'] = self.workdir['wdir']
        self.RUNTIME_YAML['ufs_modeldir'] = fix['ufs_modeldir']
        self.RUNTIME_YAML['fv3repo'] = os.path.join(os.environ.get("JEDI_SRC"), "fv3-jedi")

        self.RUNTIME_YAML['fc_length'] = config['forecast_length']
        self.RUNTIME_YAML['fc_freq'] = config['forecast_output_frequency']

        # Set the model run dir the current workdir in main config
        config['MODEL']['ufs_run_directory'] = self.workdir['wdir']

        # Use specific script
        self.command = os.path.join(config['model_path'], "tasks/runGetAnalysisUFS.py")

        self.exec_cmd = ''   # Run on login node for S3 and R2D2 Database access
        self.include_header = ''
        self.login_node_limit = 'True'
