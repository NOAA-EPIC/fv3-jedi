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
#include "atlas/functionspace.h"

#include "eckit/exception/Exceptions.h"

#include "oops/base/GeometryData.h"
#include "oops/base/Variables.h"
#include "oops/generic/GlobalInterpolator.h"
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
    time_(time)
{
  oops::Log::trace() << "State::State (from geom, vars and time) starting" << std::endl;
  fv3jedi_state_create_f90(keyState_, geom_.toFortran(), vars_, time_);
  oops::Log::trace() << "State::State (from geom, vars and time) done" << std::endl;
}

// -------------------------------------------------------------------------------------------------

State::State(const Geometry & geom, const eckit::Configuration & config)
  : geom_(geom), vars_(), time_(util::DateTime())
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
  : geom_(resol), vars_(other.vars_), time_(other.time_)
{
  oops::Log::trace() << "State::State (from geom and other) starting" << std::endl;
  fv3jedi_state_create_f90(keyState_, geom_.toFortran(), vars_, time_);
  this->changeResolution(other);
  oops::Log::trace() << "State::State (from geom and other) done" << std::endl;
}

// -------------------------------------------------------------------------------------------------

State::State(const oops::Variables & vars, const State & other) : State(other)
{
  oops::Log::trace() << "State::State (from vars and other) starting" << std::endl;
  eckit::LocalConfiguration varChangeConfig;
  VariableChange varChange(varChangeConfig, geom_);
  varChange.changeVar(*this, vars);
  oops::Log::trace() << "State::State (from vars and other) done" << std::endl;
}

// -------------------------------------------------------------------------------------------------

State::State(const State & other)
  : geom_(other.geom_), vars_(other.vars_), time_(other.time_)
{
  oops::Log::trace() << "State::State (from other) starting" << std::endl;
  std::vector indices = geom_.get_indices();
/*
  std::cout << "in copy, the indices are "; 
  for (auto i: indices)
    std::cout << i << ' ';
  std::cout << std::endl;
*/
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
  // If both states have same resolution, then copy instead of interpolating
  if (geom_.isEqual(other.geom_)) {
    fv3jedi_state_copy_f90(keyState_, other.keyState_);
    time_ = other.time_;
    return;
  }

  // Build oops interpolator -- this takes a few extra steps at this level
  const oops::GeometryData source_geom(other.geom_.functionSpace(),
                                       other.geom_.fields(),
                                       other.geom_.levelsAreTopDown(),
                                       other.geom_.getComm());
  const atlas::FunctionSpace target_fs = geom_.functionSpace();
  eckit::LocalConfiguration conf;
  // Use oops interpolator to handle integer/categorical fields correctly
  // Once the atlas interpolator gains support for this feature, we could make this configurable
  // from the user-facing yaml file; for now though, the atlas interpolator would be wrong for the
  // many integer fields of fv3-jedi.
  conf.set("local interpolator type", "oops unstructured grid interpolator");
  oops::GlobalInterpolator interp(conf, source_geom, target_fs, geom_.getComm());

  atlas::FieldSet source{};
  atlas::FieldSet target{};

  // Interpolate atlas::FieldSet representation of fv3 data
  other.toFieldSet(source);
  interp.apply(source, target);
  this->fromFieldSet(target);
}

// -------------------------------------------------------------------------------------------------

void State::updateFields(const oops::Variables & newVars) {
  const oops::Variables newLongVars = geom_.fieldsMetaData().getLongNameFromAnyName(newVars);
  vars_ = newLongVars;
  fv3jedi_state_update_fields_f90(keyState_, geom_.toFortran(), vars_);
}

// -------------------------------------------------------------------------------------------------

State & State::operator+=(const Increment & dx) {
  ASSERT(this->validTime() == dx.validTime());
  // Increment variables must be a equal to or a subset of the State variables
  ASSERT(dx.variables() <= vars_);
  // Interpolate increment to state resolution
  Increment dx_sr(geom_, dx);
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
  fv3jedi_state_to_fieldset_f90(keyState_, geom_.toFortran(), vars_, fset.get());
}

// -------------------------------------------------------------------------------------------------

void State::fromFieldSet(const atlas::FieldSet & fset) {
  fv3jedi_state_from_fieldset_f90(keyState_, geom_.toFortran(), vars_, fset.get());
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
  fv3jedi_state_deserializeSection_f90(keyState_, geom_.toFortran(), size_fld, vect.data(), isc, iec, jsc, jec,
           isc_sg, iec_sg, jsc_sg, jec_sg, ind_local);
/*
  ASSERT(vect.at(ind_local) == -54321.56789);
*/
  if(vect.at(ind_local) != -54321.56789) {
    std::cout << "Uh oh. vect @ " << ind_local << " does not equal -54321.56789. it is " << vect.at(ind_local) << std::endl;
  }
  oops::Log::trace() << "State deserializeSection done" << std::endl;
}

// -------------------------------------------------------------------------------------------------
void State::transpose(const State & FCState, const eckit::mpi::Comm & global,
    const int ensNum, const int transNum ) {

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
  const int mytask = global.rank(); 
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

  int sender_number = 0;
  std::map<int,int> send_map;
//  oops::Log::trace() << "before transpose fcst state is " << FCState << std::endl;
// TODO(mpotts) convert this loop into an allgather to collect all indices with a single call
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
      send_map[i] = sender_number;
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

  std::vector<std::vector<double> > zz_recv(senders.size());  // vector to receive send buffer

  for ( int i = 0; i < senders.size(); ++i ) {  // fill up recv buffers with zeros
    for ( int k = 0; k < zz.size(); ++k ) {  // fill up recv buffers with zeros
        zz_recv[i].push_back(0.0);
    }
  }

  for ( int j = 0; j < recipients.size(); ++j ) {  // loop through list of rcpts/sndrs and send/recv
    if (recipients[j] != mytask) {  // dont send anything to myself
      send_req_.push_back(global.iSend(&zz.front(), zz.size(), recipients[j], ensNum));
    }
  }

  for ( int j = 0; j < senders.size(); ++j ) {  // loop through list of rcpts/sndrs and send/recv
    if (senders[j] != mytask) {  // dont need to receive from myself
        recv_req_.push_back(global.iReceive(&(zz_recv[j]).front(), zz.size(), senders[j], tileEnsNum[j]));
        recv_tasks_.push_back(tileEnsNum[j]);
    } else {  // I already have this forecast state
      // copy from my local version
      size_t itask = ensNum-1;
      zz_recv[j] = zz;
      indx = 0;
      int size_fld = zz_recv[j].size();  // get the serialsize of the local tile
      this->deserializeSection(zz_recv[j], size_fld, ist_rcv, iend_rcv,
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
    int size_fld = zz_recv[rst.source()].size();  // get the serialsize of the local tile
    std::cout << "trans fc indices are " << ist_rcv <<" " <<iend_rcv <<" " <<jst_rcv <<" " <<jend_rcv << std::endl;
    std::cout << "trans da indices are " << ist_da <<" " <<iend_da <<" " <<jst_da <<" " <<jend_da << std::endl;
    this->deserializeSection(zz_recv[send_map[rst.source()]], size_fld, ist_rcv, iend_rcv,
           jst_rcv, jend_rcv, ist_da, iend_da, jst_da, jend_da, indx);  // deserialize state section
  }
  oops::mpi::world().barrier();
}
// -------------------------------------------------------------------------------------------------
void State::Rtranspose(const State & DAState, const eckit::mpi::Comm & global,
    const int ensNum, const int transNum ) {

  // This state is a FC State with the larger FC geometry 
  // this function performs a "reverse" transpose from the DAState (smaller geometry) to the 
  // larger forecast geometry. Variable transNum is the ensemble member that is currently being transposed
  int ist_fc, iend_fc, jst_fc, jend_fc, kst_fc, kend_fc, npz_fc;
  int ist_da, iend_da, jst_da, jend_da, kst_da, kend_da, npz_da;
  std::map<int, int> ist_rcv, iend_rcv, jst_rcv, jend_rcv;
  std::vector<int> local_ens;
  size_t dataSize = this->serialSize()-3;  // would be good to make this a method
  std::vector<double> zz;
  std::vector<int> buf(12);
  std::vector<int> recipients;  // This will contain list of mpi tasks where local tile will be sent
  std::vector<int> senders;  // This will contain list of mpi tasks which will be sending data to me
  std::map<int, int> mesgSize;  // This will contain list of mpi tasks which will be sending data to me
  std::vector<int> tileEnsNum;  // This will contain list of ensemble numbers that I am receiving
  int fcstTile = this->geometry().tileNum();
  std::vector<int> global_indices = this->geometry().get_indices();  // pull from this geom and
                                                                     // put into DAgeometry
  const int mytask = global.rank(); 
  ist_fc = global_indices[0];   // indices for the forecast geometry
  iend_fc = global_indices[1];
  jst_fc = global_indices[2];
  jend_fc = global_indices[3];
  kst_fc = global_indices[4];
  kend_fc = global_indices[5];
  npz_fc = global_indices[6];
  int nxg = iend_fc - ist_fc + 1;
  int nyg = jend_fc - jst_fc + 1;
  int nvars = this->variables().size();  // number of variable state
  int size_fld;
  std::vector<int> indices = DAState.geometry().get_indices();
  ist_da = indices[0];  // indices for the da geometry
  iend_da = indices[1];
  jst_da = indices[2];
  jend_da = indices[3];
  kst_da = indices[4];
  kend_da = indices[5];
  npz_da = indices[6];

  int maxSize = 0;
  int sender_number = 0;
  std::map<int,int> send_map;
//  oops::Log::trace() << "before Rtranspose fcst state is " << DAState << std::endl;
//  std::cout << "mytask is " << mytask << "fcstTile is " << fcstTile << " DAtile is " << DAState.geometry().tileNum() << std::endl;
//  this loops through every MPI task with the sender detailing what it has and what it needs 
  for (int i = 0; i < global.size(); ++i) {
    if (i == mytask) {  // mytask is global rank
      buf[0] = fcstTile;   // The tile number that this rank holds
      buf[1] = DAState.geometry().tileNum();  // The tile number that I will send
      buf[2] = ensNum;   // the ensemble number this tile belongs to
      buf[3] = ist_da;   // the start of my broadcast domain decomp in i
      buf[4] = iend_da;  // the start of my broadcast domain decomp in i
      buf[5] = jst_da;   // the start of my broadcast domain decomp in j
      buf[6] = jend_da;  // the start of my broadcast domain decomp in j
      buf[7] = ist_fc;   // the start of my i domain decomp I NEED
      buf[8] = iend_fc;  // the start of my i domain decomp I NEED
      buf[9] = jst_fc;   // the start of my j domain decomp I NEED
      buf[10] = jend_fc;  // the start of my j domain decomp I NEED
      buf[11] = DAState.serialSize();  // the size of the DAstate I will be sending
/*
    std::cout << "my buffer is -- " << std::endl;
    for (const auto& i: buf)
      std::cout << i << ' ';
    std::cout << std::endl;
*/
    }
    global.broadcast(buf, i);            
// every mpi task is now doing the following
// Each mpi task has every ensemble member on the DA state, but it
// only needs state info for its FC ensemble member (ensNum)
// figure out who is sending to me
    if ((buf[1] == fcstTile) &&   // *_fc indices will have larger span than *_da
      ((ensNum - 1)  == transNum) &&   
      ((ist_fc <= buf[3]) && (buf[4] <= iend_fc)) &&  // idxs *_da indices must be within *_fc inds
      (jst_fc <= buf[5]) && (buf[6] <= jend_fc))  //  if the tile, ist, and jst that the sender
      {                               // has matches what I need, and we r transposing this ensemble
                               // member, this is one of my senders
      ist_rcv[i] = buf[3];    // need to specify the indices of the patch that is received
      iend_rcv[i] = buf[4];    // because they may be different than the tile currently held
      jst_rcv[i] = buf[5];
      jend_rcv[i] = buf[6];
      mesgSize[i] = buf[11];
      if(buf[11] > maxSize) {
          maxSize = buf[11];
      }
      senders.push_back(i);
      send_map[i] = sender_number;
      sender_number++;
      std::cout << "I will receive states with size of " << mesgSize[i] << " from " << i << std::endl;
//      std::cout << "will receive from task " << i << " indices " << ist_rcv <<", "<<iend_rcv<<", "<< jst_rcv <<", "<<jend_rcv<<", "<<std::endl;
      tileEnsNum.push_back(buf[2]);
    }

    // now figure out who I need to send to
    if ((buf[0] == DAState.geometry().tileNum()) &&   // buf here contains indices of domain that is NEEDED by
       ((buf[2] - 1) == transNum) &&  // the other processor needs ensemble number from buf[2] and we are transposing transNum
       ((ist_da >= buf[7]) && (buf[8] >= iend_da)) &&  // NEEDED domain must be within my indices
       ((jst_da >= buf[9]) && (buf[10] >= jend_da)) ) {  //  if the DAgeometryetry tile needed
                                     // matches the tile I have, this is who I will send it to
      recipients.push_back(i);
    }
  }
    std::cout << "my recipients  -- " << std::endl;
    for (const auto& i: recipients)
    std::cout << i << ' ';
    std::cout << std::endl;
    std::cout << "my senders are -- " << std::endl;
    for (const auto& i: senders)
    std::cout << i << ' ';
    std::cout << std::endl;
/*
*/

// ---- now  send and collect messages
  std::vector<eckit::mpi::Request> send_req_;
  std::vector<eckit::mpi::Request> recv_req_;
  std::vector<size_t> recv_tasks_;
  size_t indx = 0;
  std::vector<double> yy;

  
  DAState.serialize(zz);  // serialize the DA state in time 0 and local_ens_number 0

  std::cout << "hey, zz is " << zz[0] << "," << zz[1] << "," << zz[2] << std::endl;
  std::vector<std::vector<double> > zz_recv(senders.size());  // vector to receive send buffer

  std::cout << "serializing DAstate of size " << zz.size() << " -4 is " << zz[zz.size()-4] << std::endl;
  for ( int i = 0; i < senders.size(); ++i ) {  // fill up recv buffers with zeros
    for ( int k = 0; k < maxSize; ++k ) {  // fill up recv buffers with zeros
        zz_recv[i].push_back(0.0);
    }
  }
  for ( int k = zz.size(); k < maxSize; ++k ) {
     zz.push_back(0.0);
  }
  std::cout << "DAstate is now size " << zz.size() << std::endl;

  for ( int j = 0; j < recipients.size(); ++j ) {  // loop through list of rcpts/sndrs and send/recv
    if (recipients[j] != mytask) {  // dont send anything to myself
      send_req_.push_back(global.iSend(&zz.front(), zz.size(), recipients[j], ensNum));
    } 
  }

  for ( int j = 0; j < senders.size(); ++j ) {  // loop through list of rcpts/sndrs and send/recv
    if (senders[j] != mytask) {  // dont need to receive from myself
        std::cout << "looking for message from " << senders[j] << " with size of " << mesgSize[senders[j]] << std::endl;
        recv_req_.push_back(global.iReceive(&(zz_recv[j]).front(), maxSize, senders[j], tileEnsNum[j]));
        recv_tasks_.push_back(tileEnsNum[j]);
    } else {  // I already have this DA state
      // copy from my local version
      size_t itask = ensNum-1;
      zz_recv[j] = zz;
      indx = 0;
//      int size_fld = DAState.serialSize();  // get the serialsize of the local tile
      int size_fld = zz_recv[0].size();  // get the serialsize of the local tile
      std::cout << "about to deserialize on my local tile, itask, size_fld are " << itask <<" " << size_fld << std::endl;
//      std::cout << "rcv indices are " << ist_rcv[mytask] <<" " <<iend_rcv[mytask] <<" " <<jst_rcv[mytask] <<" " <<jend_rcv[mytask] << std::endl;
      std::cout << "fc indices are " << ist_fc <<" " <<iend_fc <<" " <<jst_fc <<" " <<jend_fc << std::endl;
      std::cout << "da1 indices are " << ist_da <<" " <<iend_da <<" " <<jst_da <<" " <<jend_da << std::endl;
      std::cout << "hey, zz2 is " << zz_recv[j][0] << "," << zz_recv[j][1] << "," << zz_recv[j][2] << std::endl;
      this->deserializeSection(zz_recv[j], size_fld, ist_da, iend_da,  // we deserialized on a smaller grid, so this buffer is compact
								    // and can be unpacked without skipping
         jst_da, jend_da, ist_da, iend_da, jst_da, jend_da, indx);  // deserialize state section
    }
  }

// Start looking for messages
  for (size_t r = 0; r < recv_req_.size(); ++r) {
    int ireq = -1;
    eckit::mpi::Status rst = global.waitAny(recv_req_, ireq);
    ASSERT(rst.error() == 0);
    size_t itask = recv_tasks_[ireq] - 1;
    indx = 0;
//  size_fld = mesgSize[rst.source()]; 
    size_fld = zz_recv[rst.source()].size();  // get the serialsize of the local tile
    std::cout << "about to deserialize on my recvd tile, itask, size_fld, size_fld2, src are " << itask <<" " << size_fld <<" " << mesgSize[rst.source()] << " " <<rst.source()<< std::endl;
      std::cout << "fc indices are " << ist_fc <<" " <<iend_fc <<" " <<jst_fc <<" " <<jend_fc << std::endl;
      std::cout << "da2 indices are " << ist_rcv[rst.source()] <<" " <<iend_rcv[rst.source()] <<" " <<jst_rcv[rst.source()] <<" " <<jend_rcv[rst.source()] << std::endl;
    this->deserializeSection(zz_recv[send_map[rst.source()]], size_fld, 
//       ist_fc, iend_fc,
//       jst_fc, jend_fc,        // deserialize state section
         ist_rcv[rst.source()], iend_rcv[rst.source()],
         jst_rcv[rst.source()], jend_rcv[rst.source()],        // deserialize state section
         ist_rcv[rst.source()], iend_rcv[rst.source()],
         jst_rcv[rst.source()], jend_rcv[rst.source()], indx); 
  }
  oops::mpi::world().barrier();
  std::cout << "finished with Rtranspose of ensemble " << transNum << std::endl;
  oops::Log::trace() << "after transpose fcst state is " << *this << std::endl;
//  std::cout << "after transpose fcst state is " << *this << std::endl;
}
// -------------------------------------------------------------------------------------------------

void State::serialize(std::vector<double> & vect) const {
  oops::Log::trace() << "State serialize starting" << std::endl;
  int size_fld = this->serialSize() - 3;
  std::vector<double> v_fld(size_fld, 0);
  std::cout << "size of field for serialize is " << size_fld << std::endl;
  fv3jedi_state_serialize_f90(keyState_, size_fld, v_fld.data());
  vect.insert(vect.end(), v_fld.begin(), v_fld.end());

  
  std::cout << "vect size and size_fld are " << vect.size() << " " << size_fld << std::endl;
  // Serialize the date and time
  if(vect.size() <= size_fld) {  
    vect.push_back(-54321.56789);
  } else {
    vect[size_fld] = -54321.56789;
  }
  time_.serialize(vect);

  oops::Log::trace() << "State serialize done" << std::endl;
}

// -------------------------------------------------------------------------------------------------

void State::deserialize(const std::vector<double> & vect, size_t & index) {
  oops::Log::trace() << "State deserialize starting" << std::endl;
  fv3jedi_state_deserialize_f90(keyState_, vect.size(), vect.data(), index);

  std::cout << "vect.at(index) is " << vect.at(index) << " and index is " << index << std::endl;
//  ASSERT(vect.at(index) == -54321.56789);
  ++index;

  time_.deserialize(vect, index);
  oops::Log::trace() << "State deserialize done" << std::endl;
}

// -------------------------------------------------------------------------------------------------

}  // namespace fv3jedi
