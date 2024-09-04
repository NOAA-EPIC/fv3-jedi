/*
 * (C) Copyright 2017-2022 UCAR
 *
 * This software is licensed under the terms of the Apache Licence Version 2.0
 * which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
 */

#include <algorithm>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "boost/none_t.hpp"

#include "atlas/field.h"

#include "eckit/exception/Exceptions.h"

#include "oops/base/Variables.h"
#include "oops/util/abor1_cpp.h"
#include "oops/util/DateTime.h"
#include "oops/util/Duration.h"
#include "oops/util/Logger.h"

#include "fv3jedi/Geometry/Geometry.h"
#include "fv3jedi/Increment/Increment.h"
#include "fv3jedi/IO/Utils/IOBase.h"
#include "fv3jedi/State/State.h"
#include "fv3jedi/VariableChange/VariableChange.h"

namespace fv3jedi {

// -------------------------------------------------------------------------------------------------

State::State(const Geometry & geom, const oops::Variables & vars, const util::DateTime & time)
  : geom_(geom),
    vars_(geom_.fieldsMetaData().getLongNameFromAnyName(vars)),
    varsJedi_(geom_.fieldsMetaData().removeInterfaceSpecificFields(vars)),
    time_(time)
{
  oops::Log::trace() << "State::State (from geom, vars and time) starting" << std::endl;
  fv3jedi_state_create_f90(keyState_, geom_.toFortran(), vars_, time_);
  oops::Log::trace() << "State::State (from geom, vars and time) done" << std::endl;
}

// -------------------------------------------------------------------------------------------------

State::State(const Geometry & geom, const eckit::Configuration & config)
  : geom_(geom), vars_(), varsJedi_(), time_(util::DateTime())
{
  oops::Log::trace() << "State::State (from geom and parameters) starting" << std::endl;
  StateParameters params;
  params.deserialize(config);

  // Set up vars
  if (params.analytic.value() != boost::none) {
    // Variables are hard coded for analytic initial condition (must not be provided)
    ASSERT(params.stateVariables.value() == boost::none);
    vars_ = oops::Variables({"ua", "va", "t", "delp", "p", "sphum", "ice_wat", "liq_wat", "phis",
                             "o3mr", "w"});
  } else {
    // If variables are being read they must be defined in the config
    ASSERT(params.stateVariables.value() != boost::none);
    vars_ = oops::Variables(*params.stateVariables.value());
  }
  stdvars_ = vars_;  // The original "standard" names are required by NUOPC_Advertise

  // Set long name variables
  vars_ = geom_.fieldsMetaData().getLongNameFromAnyName(vars_);
  varsJedi_ = geom_.fieldsMetaData().removeInterfaceSpecificFields(vars_);

  // Datetime from the config for read and analytical
  ASSERT(params.datetime.value() != boost::none);
  time_ = util::DateTime(*params.datetime.value());

  // Datetime from the config for read and analytical
  ASSERT(params.datetime.value() != boost::none);
  time_ = util::DateTime(*params.datetime.value());

  // Allocate state
  fv3jedi_state_create_f90(keyState_, geom_.toFortran(), vars_, time_);

  // Generate analytical state or read from file
  if (params.analytic.value() != boost::none) {
    this->analytic_init(params.analytic.value()->toConfiguration(), geom);
  } else {
    this->read(params.toConfiguration());
  }

  oops::Log::trace() << "State::State (from geom and parameters) done" << std::endl;
}

// -------------------------------------------------------------------------------------------------

State::State(const Geometry & resol, const State & other)
  : geom_(resol), vars_(other.vars_), varsJedi_(other.varsJedi_), time_(other.time_)
{
  oops::Log::trace() << "State::State (from geom and other) starting" << std::endl;
  fv3jedi_state_create_f90(keyState_, geom_.toFortran(), vars_, time_);
  fv3jedi_state_change_resol_f90(keyState_, geom_.toFortran(), other.keyState_,
                                 other.geom_.toFortran());
  oops::Log::trace() << "State::State (from geom and other) done" << std::endl;
}

// -------------------------------------------------------------------------------------------------

State::State(const oops::Variables & vars, const State & other) : State(other)
{
  oops::Log::trace() << "State::State (from vars and other) starting" << std::endl;
  eckit::LocalConfiguration varChangeConfig;
  varChangeConfig.set("variable change name", "Analysis2Model");
  VariableChange an2model(varChangeConfig, geom_);
  an2model.changeVarInverse(*this, vars);
  oops::Log::trace() << "State::State (from vars and other) done" << std::endl;
}

// -------------------------------------------------------------------------------------------------

State::State(const State & other)
  : geom_(other.geom_), vars_(other.vars_), varsJedi_(other.varsJedi_), time_(other.time_)
{
  oops::Log::trace() << "State::State (from other) starting" << std::endl;
  fv3jedi_state_create_f90(keyState_, geom_.toFortran(), vars_, time_);
  fv3jedi_state_copy_f90(keyState_, other.keyState_);
  oops::Log::trace() << "State::State (from other) done" << std::endl;
}

// -------------------------------------------------------------------------------------------------

State::~State() {
  fv3jedi_state_delete_f90(keyState_);
}

// -------------------------------------------------------------------------------------------------

State & State::operator=(const State & rhs) {
  fv3jedi_state_copy_f90(keyState_, rhs.keyState_);
  time_ = rhs.time_;
  return *this;
}

// -------------------------------------------------------------------------------------------------

void State::changeResolution(const State & other) {
  fv3jedi_state_change_resol_f90(keyState_, geom_.toFortran(), other.keyState_,
                                 other.geom_.toFortran());
}

// -------------------------------------------------------------------------------------------------

void State::updateFields(const oops::Variables & newVars) {
  const oops::Variables newLongVars = geom_.fieldsMetaData().getLongNameFromAnyName(newVars);
  vars_ = newLongVars;
  varsJedi_ = geom_.fieldsMetaData().removeInterfaceSpecificFields(newLongVars);
  fv3jedi_state_update_fields_f90(keyState_, geom_.toFortran(), vars_);
}

// -------------------------------------------------------------------------------------------------

State & State::operator+=(const Increment & dx) {
  ASSERT(this->validTime() == dx.validTime());
  // Increment variables must be a equal to or a subset of the State variables
  ASSERT(dx.variables() <= vars_);
  // Interpolate increment to state resolution
  Increment dx_sr(geom_, dx);
  // Make sure State's data representations are synchronized.
  // Note: empirically, this is not needed (as of Oct 2023) for Variational applications, but is
  // needed for EnsRecenter, because that adds an increment to an *interpolated* state.
  this->synchronizeInterfaceFields();
  // Call transform and add
  fv3jedi_state_add_increment_f90(keyState_, dx_sr.toFortran(), geom_.toFortran());
  return *this;
}

// -------------------------------------------------------------------------------------------------

void State::analytic_init(const eckit::Configuration & config, const Geometry & geom) {
  fv3jedi_state_analytic_init_f90(keyState_, geom.toFortran(), config);
}

// -------------------------------------------------------------------------------------------------

void State::read(const eckit::Configuration & config) {
  StateParameters params;
  params.deserialize(config);
  // Optionally set the datetime on read (needed for some bump applications)
  if (params.setdatetime.value() != boost::none) {
    if (*params.setdatetime.value() && params.datetime.value() != boost::none) {
      time_ = *params.datetime.value();
    }
  }
  IOBase_ io(IOFactory::create(geom_, *params.ioParametersWrapper.ioParameters.value()));
  io->read(*this);
}

// -------------------------------------------------------------------------------------------------

void State::write(const eckit::Configuration & config) const {
  StateWriteParameters params;
  params.deserialize(config);
  IOBase_ io(IOFactory::create(geom_, *params.ioParametersWrapper.ioParameters.value()));

  this->synchronizeInterfaceFields();
  io->write(*this);
}

// -------------------------------------------------------------------------------------------------

void State::print(std::ostream & os) const {
  // Get the number of fields
  int numberFields;
  int cubeSize;
  fv3jedi_state_getnfieldsncube_f90(keyState_, numberFields, cubeSize);

  // Header
  os << std::endl
     << "--------------------------------------------------"
        "--------------------------------------------------";
  os << std::endl << "State print | number of fields = " << numberFields
                  << " | cube sphere face size: C" << cubeSize;

  // Print info field by field
  const int FieldNameLen = 45;
  char fieldName[FieldNameLen];
  std::vector<double> minMaxRms(3);
  for (int f = 0; f < numberFields; f++) {
    int fp1 = f+1;
    fv3jedi_state_getminmaxrms_f90(keyState_, fp1, FieldNameLen-1, fieldName, minMaxRms[0]);
    std::string fieldNameStr(fieldName);
    os << std::endl << std::scientific << std::showpos << fieldNameStr.substr(0, FieldNameLen-1)
                    << " | Min:" << minMaxRms[0] << " Max:" << minMaxRms[1]
                    << " RMS:" << minMaxRms[2] << std::noshowpos;
  }

  os.unsetf(std::ios_base::floatfield);

  // Footer
  os << std::endl
     << "--------------------------------------------------"
        "--------------------------------------------------";
}

// -------------------------------------------------------------------------------------------------

void State::zero() {
  fv3jedi_state_zero_f90(keyState_);
}

// -------------------------------------------------------------------------------------------------

void State::accumul(const double & zz, const State & xx) {
  fv3jedi_state_axpy_f90(keyState_, zz, xx.keyState_);
}

// -------------------------------------------------------------------------------------------------

double State::norm() const {
  double zz = 0.0;
  fv3jedi_state_norm_f90(keyState_, zz);
  return zz;
}

// -------------------------------------------------------------------------------------------------

void State::toFieldSet(atlas::FieldSet & fset) const {
  fv3jedi_state_to_fieldset_f90(keyState_, geom_.toFortran(), varsJedi_, fset.get());
}

// -------------------------------------------------------------------------------------------------

void State::fromFieldSet(const atlas::FieldSet & fset) {
  fv3jedi_state_from_fieldset_f90(keyState_, geom_.toFortran(), varsJedi_, fset.get());
}

// -------------------------------------------------------------------------------------------------

void State::synchronizeInterfaceFields() const {
  fv3jedi_state_synchronize_interface_fields_f90(keyState_, geom_.toFortran());
}

// -----------------------------------------------------------------------------

void State::setInterfaceFieldsOutOfDate(const bool outofdate) const {
  fv3jedi_state_set_interface_fields_outofdate_f90(keyState_, outofdate);
}

// -----------------------------------------------------------------------------

size_t State::serialSize() const {
  oops::Log::trace() << "State serialSize starting" << std::endl;
  size_t nn = 1;
  int sz = 0;
  fv3jedi_state_sersize_f90(keyState_, sz);
  nn += sz;
  nn += time_.serialSize();
  oops::Log::trace() << "State serialSize done" << std::endl;
  return nn;
}

// -------------------------------------------------------------------------------------------------

void State::deserializeSection(const std::vector<double> & vect, int & size_fld, int & isc,
     int & iec, int & jsc, int & jec, int & isc_sg, int & iec_sg, int & jsc_sg, int & jec_sg,
     size_t & ind_local) {
  oops::Log::trace() << "State deserialize starting" << std::endl;
  fv3jedi_state_deserializeSection_f90(keyState_, size_fld, vect.data(), isc, iec, jsc, jec,
           isc_sg, iec_sg, jsc_sg, jec_sg, ind_local);

  ASSERT(vect.at(ind_local) == -54321.56789);
  oops::Log::trace() << "State deserializeSection done" << std::endl;
}

// -------------------------------------------------------------------------------------------------
void State::transpose(const State & FCState, const eckit::mpi::Comm & global, const int & mytask,
    const int & ensNum, const int & transNum ) {

  int ist_fc, iend_fc, jst_fc, jend_fc, kst_fc, kend_fc, npz_fc;
  int ist_da, iend_da, jst_da, jend_da, kst_da, kend_da, npz_da;
  int ist_rcv, iend_rcv, jst_rcv, jend_rcv, kst_rcv, kend_rcv, npz_rcv;
  std::vector<int> local_ens;
  size_t dataSize = FCState.serialSize()-3;  // would be good to make this a method
  std::vector<double> zz;
  std::vector<int> buf(11);
  std::vector<int> recipients;  // This will contain list of mpi tasks where local tile will be sent
  std::vector<int> senders;  // This will contain list of mpi tasks which will be sending data to me
  std::vector<int> tileEnsNum;  // This will contain list of ensemble numbers that I am receiving
  int mytile = FCState.geometry().tileNum();
  std::vector<int> global_indices = FCState.geometry().get_indices();  // pull from this geom and
                                                                     // put into DAgeometry
  std::vector<State> localstates;
  ist_fc = global_indices[0];   // indices for the forecast geometry
  iend_fc = global_indices[1];
  jst_fc = global_indices[2];
  jend_fc = global_indices[3];
  kst_fc = global_indices[4];
  kend_fc = global_indices[5];
  npz_fc = global_indices[6];
  int nxg = iend_fc - ist_fc + 1;
  int nyg = jend_fc - jst_fc + 1;
  int nvars = FCState.variables().size();  // number of variable state

  std::vector<int> indices = this->geometry().get_indices();
  ist_da = indices[0];  // indices for the da geometry
  iend_da = indices[1];
  jst_da = indices[2];
  jend_da = indices[3];
  kst_da = indices[4];
  kend_da = indices[5];
  npz_da = indices[6];

  oops::Log::trace() << "before transpose fcst state is " << FCState << std::endl;
  for (int i = 0; i < global.size(); ++i) {
    if (i == mytask) {  // mytask is global rank
      buf[0] = mytile;   // The tile number that this rank holds
      buf[1] = this->geometry().tileNum();  // The tile number that I need
      buf[2] = ensNum;   // the ensemble number this tile belongs to
      buf[3] = ist_fc;   // the start of my broadcast domain decomp in i
      buf[4] = iend_fc;  // the start of my broadcast domain decomp in i
      buf[5] = jst_fc;   // the start of my broadcast domain decomp in j
      buf[6] = jend_fc;  // the start of my broadcast domain decomp in j
      buf[7] = ist_da;   // the start of my i domain decomp I NEED
      buf[8] = iend_da;  // the start of my i domain decomp I NEED
      buf[9] = jst_da;   // the start of my j domain decomp I NEED
      buf[10] = jend_da;  // the start of my j domain decomp I NEED
    }
    global.broadcast(buf, i);                 // This is to figure out who is sending domain I NEED
    if ((buf[0] == this->geometry().tileNum()) &&   // *_fc indices will have larger span than *_da
      ((buf[3] <= ist_da) && (iend_da <= buf[4])) &&  // idxs *_da indices must be within *_fc inds
      ((buf[5] <= jst_da) && (jend_da <= buf[6])) &&  //  if the tile, ist, and jst that the sender
      ((buf[2] - 1) == transNum)) {  // has matches what I need, and we r transposing this ensemble
                               // member, this is one of my senders
      senders.push_back(i);
      ist_rcv = buf[3];    // need to specify the indices of the patch that is received
      iend_rcv = buf[4];    // because they may be different than the tile currently held
      jst_rcv = buf[5];
      jend_rcv = buf[6];
      tileEnsNum.push_back(buf[2]);
    }
    if ((buf[1] == mytile) &&   // buf here contains indices of domain that is NEEDED by
       ((ensNum - 1) == transNum) &&  // the other processor
       ((ist_fc <= buf[7]) && (buf[8] <= iend_fc)) &&  // NEEDED domain must be within my indices
       ((jst_fc <= buf[9]) && (buf[10] <= jend_fc)) ) {  //  if the DAgeometryetry tile needed
                                     // matches the tile I have, this is who I will send it to
      recipients.push_back(i);
    }
  }

// ---- now  send and collect messages
  std::vector<eckit::mpi::Request> send_req_;
  std::vector<eckit::mpi::Request> recv_req_;
  std::vector<size_t> recv_tasks_;
  size_t indx = 0;
  std::vector<double> yy;

  FCState.serialize(zz);  // serialize the forecast state in time 0 and local_ens_number 0

  std::vector<double>  zz_recv(zz.size());  // vector to receive send buffer

  for ( int k = 0; k < zz.size(); ++k ) {  // fill up recv buffers with zeros
        zz_recv.push_back(0.0);
  }

  for ( int j = 0; j < recipients.size(); ++j ) {  // loop through list of rcpts/sndrs and send/recv
    if (recipients[j] != mytask) {  // dont send anything to myself
      send_req_.push_back(global.iSend(&zz.front(), zz.size(), recipients[j], ensNum));
    }
  }

  for ( int j = 0; j < senders.size(); ++j ) {  // loop through list of rcpts/sndrs and send/recv
    if (senders[j] != mytask) {  // dont need to receive from myself
        recv_req_.push_back(global.iReceive(&zz_recv[0], zz.size(), senders[j], tileEnsNum[j]));
        recv_tasks_.push_back(tileEnsNum[j]);
    } else {  // I already have this forecast state
      // copy from my local version
      size_t itask = ensNum-1;
      zz_recv = zz;
      indx = 0;
      int size_fld = zz_recv.size();  // get the serialsize of the local tile
      this->deserializeSection(zz_recv, size_fld, ist_rcv, iend_rcv,
         jst_rcv, jend_rcv, ist_da, iend_da, jst_da, jend_da, indx);  // deserialize state section
    }
  }

// Start looking for messages
  for (size_t r = 0; r < recv_req_.size(); ++r) {
    int ireq = -1;
    eckit::mpi::Status rst = global.waitAny(recv_req_, ireq);
    ASSERT(rst.error() == 0);
    size_t itask = recv_tasks_[ireq] - 1;
    indx = 0;
    int size_fld = zz_recv.size();  // get the serialsize of the local tile
    this->deserializeSection(zz_recv, size_fld, ist_rcv, iend_rcv,
           jst_rcv, jend_rcv, ist_da, iend_da, jst_da, jend_da, indx);  // deserialize state section
  }
  oops::mpi::world().barrier();
}
// -------------------------------------------------------------------------------------------------

void State::serialize(std::vector<double> & vect) const {
  oops::Log::trace() << "State serialize starting" << std::endl;
  int size_fld = this->serialSize() - 3;
  std::vector<double> v_fld(size_fld, 0);

  fv3jedi_state_serialize_f90(keyState_, size_fld, v_fld.data());
  vect.insert(vect.end(), v_fld.begin(), v_fld.end());

  // Serialize the date and time
  vect.push_back(-54321.56789);
  time_.serialize(vect);

  oops::Log::trace() << "State serialize done" << std::endl;
}

// -------------------------------------------------------------------------------------------------

void State::deserialize(const std::vector<double> & vect, size_t & index) {
  oops::Log::trace() << "State deserialize starting" << std::endl;
  fv3jedi_state_deserialize_f90(keyState_, vect.size(), vect.data(), index);

  ASSERT(vect.at(index) == -54321.56789);
  ++index;

  time_.deserialize(vect, index);
  oops::Log::trace() << "State deserialize done" << std::endl;
}

// -------------------------------------------------------------------------------------------------

}  // namespace fv3jedi
