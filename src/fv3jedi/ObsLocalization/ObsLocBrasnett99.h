/*
 * (C) Copyright 2020-2021 UCAR
 *
 * This software is licensed under the terms of the Apache Licence Version 2.0
 * which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
 */

#pragma once

#include <ostream>
#include <vector>

#include "ioda/ObsSpace.h"
#include "ioda/ObsVector.h"

#include "ufo/obslocalization/ObsHorLocSOAR.h"
#include "ufo/obslocalization/ObsHorLocSOARParameters.h"

namespace fv3jedi {

/// \brief Options controlling Brasnett 99 observation space localization
/// for snow DA.
class ObsLocBrasnettParameters : public ufo::ObsHorLocSOARParameters {
  OOPS_CONCRETE_PARAMETERS(ObsLocBrasnettParameters, ufo::ObsHorLocSOARParameters)

 public:
  oops::Parameter<double> vertscale{"vertical lengthscale",
                 "lengthscale of vertical localization in meters", 800., this};
};

/// Brasnett 99 observation space localization for snow DA
/// https://doi.org/10.1175/1520-0450(1999)038<0726:AGAOSD>2.0.CO;2
/// Note, Brasnett99 adds vertical localization to the horizontal SOAR function
/// Hence, we inherit from ufo::ObsLocSOAR
template<class MODEL>
class ObsLocBrasnett99: public ufo::ObsHorLocSOAR<MODEL> {
  typedef typename MODEL::GeometryIterator   GeometryIterator_;
  typedef typename ufo::ObsHorLocalization<MODEL>::LocalObs LocalObs_;

 public:
  typedef ObsLocBrasnettParameters Parameters_;
  ObsLocBrasnett99(const Parameters_ &, const ioda::ObsSpace &);

 protected:
  /// compute localization and update localization values in \p locvector
  /// (missing values for observations outside of localization)
  void localizeLocalObs(const GeometryIterator_ &,
                        ioda::ObsVector & locvector,
                        const LocalObs_ &) const override;

 private:
  void print(std::ostream &) const override;
  std::vector<float> obsHeight_;  //< height of observations
  double VertScale_;  //< vertical localization scale
};
// -----------------------------------------------------------------------------
template<typename MODEL>
ObsLocBrasnett99<MODEL>::ObsLocBrasnett99(const Parameters_ & params,
                                          const ioda::ObsSpace & obsspace):
       ufo::ObsHorLocSOAR<MODEL>::ObsHorLocSOAR(params, obsspace),
       obsHeight_(obsspace.nlocs()),
       VertScale_(params.vertscale) {
  oops::Log::trace()<< "Brasnett99 localization with: vertical scale=" << VertScale_
                    << std::endl;

  // read height of measurements
  obsspace.get_db("MetaData", "height", obsHeight_);
}
// -----------------------------------------------------------------------------

template<typename MODEL>
void ObsLocBrasnett99<MODEL>::localizeLocalObs(const GeometryIterator_ & geoiter,
                                               ioda::ObsVector & locvector,
                                               const LocalObs_ & localobs) const {
  oops::Log::trace() << "ObsLocBrasnett99::computeLocalization" << std::endl;

  // compute horizontal localization using SOAR
  ufo::ObsHorLocSOAR<MODEL>::localizeLocalObs(geoiter, locvector, localobs);

  // retrieve orography for this grid point
  double orog = geoiter.getOrography();
  oops::Log::debug() << "geoiter=" << geoiter << " orog=" << orog << std::endl;

  // compute vertical localization and multiply it by SOAR computed above
  // vloc=exp(- (dz/hfac)^2 )
  const size_t nvars = locvector.nvars();
  for (size_t jlocal = 0; jlocal < localobs.index.size(); ++jlocal) {
    double locFactor = std::exp(-std::pow((obsHeight_[localobs.index[jlocal]] - orog)
                                          /VertScale_, 2));
    // obsdist is calculated at each location; need to update R for each variable
    for (size_t jvar = 0; jvar < nvars; ++jvar) {
      locvector[jvar + localobs.index[jlocal] * nvars] *= locFactor;
    }
  }
}

// -----------------------------------------------------------------------------

template<typename MODEL>
void ObsLocBrasnett99<MODEL>::print(std::ostream & os) const {
//  this->print(os);
  os << "Brasnett99 localization with: vertical scale=" << VertScale_
                    << std::endl;
}

}  // namespace fv3jedi