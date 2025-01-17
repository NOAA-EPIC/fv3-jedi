/*
 * (C) Copyright 2017 UCAR
 *
 * This software is licensed under the terms of the Apache Licence Version 2.0
 * which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
 */

#pragma once

#include <memory>
#include <ostream>
#include <string>
#include <vector>

#include "atlas/field.h"
#include "atlas/functionspace.h"

#include "eckit/config/Configuration.h"
#include "eckit/mpi/Comm.h"

#include "oops/mpi/mpi.h"
#include "oops/util/ObjectCounter.h"
#include "oops/util/Printable.h"

#include "fv3jedi/FieldMetadata/FieldsMetadata.h"
#include "fv3jedi/Geometry/Geometry.interface.h"
#include "fv3jedi/GeometryIterator/GeometryIterator.h"

namespace oops {
  class Variables;
}

namespace fv3jedi {
  class GeometryIterator;

// -------------------------------------------------------------------------------------------------
/// Geometry handles geometry for FV3JEDI model.

class Geometry : public util::Printable,
                 private util::ObjectCounter<Geometry> {
 public:
  static const std::string classname() {return "fv3jedi::Geometry";}

  explicit Geometry(const eckit::Configuration &, const eckit::mpi::Comm &);
  Geometry(const Geometry &);
  ~Geometry();

  Geometry & operator=(const Geometry &) = delete;

  // For use by other fv3jedi code
  bool isEqual(const Geometry &) const;

  bool levelsAreTopDown() const {return true;}

  GeometryIterator begin() const;
  GeometryIterator end() const;
  std::vector<double> verticalCoord(std::string &) const;

  F90geom & toFortran() {return keyGeom_;}
  const F90geom & toFortran() const {return keyGeom_;}
  const eckit::mpi::Comm & getComm() const {return comm_;}
  const atlas::FunctionSpace & functionSpace() const {return functionSpace_;}
  const atlas::FieldSet & fields() const {return fields_;}

  int tileNum() const {return tileNum_;}
  std::vector<int> get_indices() const {
     int ist, iend, jst, jend, kst, kend, npz;
     std::vector<int> indices;
     fv3jedi_geom_start_end_f90(keyGeom_, ist, iend, jst, jend, kst, kend, npz);
     indices.push_back(ist);
     indices.push_back(iend);
     indices.push_back(jst);
     indices.push_back(jend);
     indices.push_back(kst);
     indices.push_back(kend);
     indices.push_back(npz);
     return indices;
  }

  std::vector<size_t> variableSizes(const oops::Variables &) const;

  const FieldsMetadata & fieldsMetaData() const {return *fieldsMeta_;}

  // Functions to retrieve geometry features
  const std::vector<double> & ak() const {return ak_;}
  const std::vector<double> & bk() const {return bk_;}
  const double & pTop() const {return pTop_;}
  const int & nLevels() const {return nLevels_;}

 private:
  void print(std::ostream &) const;

  F90geom keyGeom_;
  const eckit::mpi::Comm & comm_;
  atlas::FunctionSpace functionSpace_;
  // temporary hack: FunctionSpace without halos for calling BUMP interpolation from within fv3jedi
  atlas::FunctionSpace functionSpaceForBump_;
  atlas::FieldSet fields_;
  std::shared_ptr<FieldsMetadata> fieldsMeta_;
  std::vector<double> ak_;
  std::vector<double> bk_;
  int tileNum_;
  int nLevels_;
  double pTop_;
};
// -------------------------------------------------------------------------------------------------

}  // namespace fv3jedi
