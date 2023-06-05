# (C) Copyright 2023 UCAR
#
# This software is licensed under the terms of the Apache Licence Version 2.0
# which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
import gfs

import forecastUFS
import getAnalysisUFS
import getBackgroundUFS
import getExpInitUFS
import getFcInitUFS
import getFixFilesUFS
import saveForecastUFS

class ModelTasks(gfs.ModelTasks):

    def __init__(self):
        gfs.ModelTasks.__init__(self)

        self.forecast = forecastUFS.forecastUFS
        self.getAnalysis = getAnalysisUFS.getAnalysisUFS
        self.getBackground = getBackgroundUFS.getBackgroundUFS
        self.getExpInit = getExpInitUFS.getExpInitUFS
        self.getFcInit = getFcInitUFS.getFcInitUFS
        self.getStaticModel = getFixFilesUFS.getFixFilesUFS
        self.saveForecast = saveForecastUFS.saveForecastUFS
