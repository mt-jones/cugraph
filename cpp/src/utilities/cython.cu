/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <algorithms.hpp>
#include <experimental/graph_view.hpp>
#include <graph.hpp>
#include <partition_manager.hpp>
#include <raft/handle.hpp>
#include <utilities/cython.hpp>
#include <utilities/error.hpp>

#include <rmm/thrust_rmm_allocator.h>
#include <thrust/copy.h>
#include <thrust/iterator/counting_iterator.h>

namespace cugraph {
namespace cython {

namespace detail {

// FIXME: Add description of this function
template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool transposed,
          bool multi_gpu,
          std::enable_if_t<multi_gpu>* = nullptr>
std::unique_ptr<experimental::graph_t<vertex_t, edge_t, weight_t, transposed, multi_gpu>>
create_graph(raft::handle_t const& handle, graph_container_t const& graph_container)
{
  std::vector<experimental::edgelist_t<vertex_t, edge_t, weight_t>> edgelist(
    {{reinterpret_cast<vertex_t*>(graph_container.src_vertices),
      reinterpret_cast<vertex_t*>(graph_container.dst_vertices),
      reinterpret_cast<weight_t*>(graph_container.weights),
      static_cast<edge_t>(graph_container.num_partition_edges)}});

  std::vector<vertex_t> partition_offsets_vector(
    reinterpret_cast<vertex_t*>(graph_container.vertex_partition_offsets),
    reinterpret_cast<vertex_t*>(graph_container.vertex_partition_offsets) +
      (graph_container.row_comm_size * graph_container.col_comm_size) + 1);

  experimental::partition_t<int> partition(partition_offsets_vector,
                                           graph_container.hypergraph_partitioned,
                                           graph_container.row_comm_size,
                                           graph_container.col_comm_size,
                                           graph_container.row_comm_rank,
                                           graph_container.col_comm_rank);

  return std::make_unique<experimental::graph_t<vertex_t, edge_t, weight_t, transposed, multi_gpu>>(
    handle,
    edgelist,
    partition,
    static_cast<vertex_t>(graph_container.num_global_vertices),
    static_cast<edge_t>(graph_container.num_global_edges),
    graph_container.graph_props,
    graph_container.sorted_by_degree,
    graph_container.do_expensive_check);
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool transposed,
          bool multi_gpu,
          std::enable_if_t<!multi_gpu>* = nullptr>
std::unique_ptr<experimental::graph_t<vertex_t, edge_t, weight_t, transposed, multi_gpu>>
create_graph(raft::handle_t const& handle, graph_container_t const& graph_container)
{
  experimental::edgelist_t<vertex_t, edge_t, weight_t> edgelist{
    reinterpret_cast<vertex_t*>(graph_container.src_vertices),
    reinterpret_cast<vertex_t*>(graph_container.dst_vertices),
    reinterpret_cast<weight_t*>(graph_container.weights),
    static_cast<edge_t>(graph_container.num_partition_edges)};

  return std::make_unique<experimental::graph_t<vertex_t, edge_t, weight_t, transposed, multi_gpu>>(
    handle,
    edgelist,
    static_cast<vertex_t>(graph_container.num_global_vertices),
    graph_container.graph_props,
    graph_container.sorted_by_degree,
    graph_container.do_expensive_check);
}

}  // namespace detail

// Populates a graph_container_t with a pointer to a new graph object and sets
// the meta-data accordingly.  The graph container owns the pointer and it is
// assumed it will delete it on destruction.
void populate_graph_container(graph_container_t& graph_container,
                              raft::handle_t& handle,
                              void* src_vertices,
                              void* dst_vertices,
                              void* weights,
                              void* vertex_partition_offsets,
                              numberTypeEnum vertexType,
                              numberTypeEnum edgeType,
                              numberTypeEnum weightType,
                              size_t num_partition_edges,
                              size_t num_global_vertices,
                              size_t num_global_edges,
                              size_t row_comm_size,  // pcols
                              size_t col_comm_size,  // prows
                              bool sorted_by_degree,
                              bool transposed,
                              bool multi_gpu)
{
  CUGRAPH_EXPECTS(graph_container.graph_type == graphTypeEnum::null,
                  "populate_graph_container() can only be called on an empty container.");

  bool do_expensive_check{false};
  bool hypergraph_partitioned{false};

  // FIXME: Consider setting up the subcomms right after initializing comms, no
  // need to delay to this point.
  // Setup the subcommunicators needed for this partition on the handle.
  partition_2d::subcomm_factory_t<partition_2d::key_naming_t, int> subcomm_factory(handle,
                                                                                   row_comm_size);
  // FIXME: once the subcomms are set up earlier (outside this function), remove
  // the row/col_comm_size params and retrieve them from the handle (commented
  // out lines below)
  auto& row_comm           = handle.get_subcomm(cugraph::partition_2d::key_naming_t().row_name());
  auto const row_comm_rank = row_comm.get_rank();
  // auto const row_comm_size = row_comm.get_size(); // pcols
  auto& col_comm           = handle.get_subcomm(cugraph::partition_2d::key_naming_t().col_name());
  auto const col_comm_rank = col_comm.get_rank();
  // auto const col_comm_size = col_comm.get_size(); // prows

  graph_container.vertex_partition_offsets = vertex_partition_offsets;
  graph_container.src_vertices             = src_vertices;
  graph_container.dst_vertices             = dst_vertices;
  graph_container.weights                  = weights;
  graph_container.num_partition_edges      = num_partition_edges;
  graph_container.num_global_vertices      = num_global_vertices;
  graph_container.num_global_edges         = num_global_edges;
  graph_container.vertexType               = vertexType;
  graph_container.edgeType                 = edgeType;
  graph_container.weightType               = weightType;
  graph_container.transposed               = transposed;
  graph_container.is_multi_gpu             = multi_gpu;
  graph_container.hypergraph_partitioned   = hypergraph_partitioned;
  graph_container.row_comm_size            = row_comm_size;
  graph_container.col_comm_size            = col_comm_size;
  graph_container.row_comm_rank            = row_comm_rank;
  graph_container.col_comm_rank            = col_comm_rank;
  graph_container.sorted_by_degree         = sorted_by_degree;
  graph_container.do_expensive_check       = do_expensive_check;

  experimental::graph_properties_t graph_props{.is_symmetric = false, .is_multigraph = false};
  graph_container.graph_props = graph_props;

  graph_container.graph_type = graphTypeEnum::graph_t;
}

void populate_graph_container_legacy(graph_container_t& graph_container,
                                     graphTypeEnum legacyType,
                                     raft::handle_t const& handle,
                                     void* offsets,
                                     void* indices,
                                     void* weights,
                                     numberTypeEnum offsetType,
                                     numberTypeEnum indexType,
                                     numberTypeEnum weightType,
                                     size_t num_global_vertices,
                                     size_t num_global_edges,
                                     int* local_vertices,
                                     int* local_edges,
                                     int* local_offsets)
{
  CUGRAPH_EXPECTS(graph_container.graph_type == graphTypeEnum::null,
                  "populate_graph_container() can only be called on an empty container.");

  // FIXME: This is soon-to-be legacy code left in place until the new graph_t
  // class is supported everywhere else. Remove everything down to the comment
  // line after the return stmnt.
  // Keep new code below return stmnt enabled to ensure it builds.
  if (weightType == numberTypeEnum::floatType) {
    switch (legacyType) {
      case graphTypeEnum::LegacyCSR: {
        graph_container.graph_ptr_union.GraphCSRViewFloatPtr =
          std::make_unique<GraphCSRView<int, int, float>>(reinterpret_cast<int*>(offsets),
                                                          reinterpret_cast<int*>(indices),
                                                          reinterpret_cast<float*>(weights),
                                                          num_global_vertices,
                                                          num_global_edges);
        graph_container.graph_type = graphTypeEnum::GraphCSRViewFloat;
        (graph_container.graph_ptr_union.GraphCSRViewFloatPtr)
          ->set_local_data(local_vertices, local_edges, local_offsets);
        (graph_container.graph_ptr_union.GraphCSRViewFloatPtr)
          ->set_handle(const_cast<raft::handle_t*>(&handle));
      } break;
      case graphTypeEnum::LegacyCSC: {
        graph_container.graph_ptr_union.GraphCSCViewFloatPtr =
          std::make_unique<GraphCSCView<int, int, float>>(reinterpret_cast<int*>(offsets),
                                                          reinterpret_cast<int*>(indices),
                                                          reinterpret_cast<float*>(weights),
                                                          num_global_vertices,
                                                          num_global_edges);
        graph_container.graph_type = graphTypeEnum::GraphCSCViewFloat;
        (graph_container.graph_ptr_union.GraphCSCViewFloatPtr)
          ->set_local_data(local_vertices, local_edges, local_offsets);
        (graph_container.graph_ptr_union.GraphCSCViewFloatPtr)
          ->set_handle(const_cast<raft::handle_t*>(&handle));
      } break;
      case graphTypeEnum::LegacyCOO: {
        graph_container.graph_ptr_union.GraphCOOViewFloatPtr =
          std::make_unique<GraphCOOView<int, int, float>>(reinterpret_cast<int*>(offsets),
                                                          reinterpret_cast<int*>(indices),
                                                          reinterpret_cast<float*>(weights),
                                                          num_global_vertices,
                                                          num_global_edges);
        graph_container.graph_type = graphTypeEnum::GraphCOOViewFloat;
        (graph_container.graph_ptr_union.GraphCOOViewFloatPtr)
          ->set_local_data(local_vertices, local_edges, local_offsets);
        (graph_container.graph_ptr_union.GraphCOOViewFloatPtr)
          ->set_handle(const_cast<raft::handle_t*>(&handle));
      } break;
      default: CUGRAPH_FAIL("unsupported graphTypeEnum value"); break;
    }

  } else {
    switch (legacyType) {
      case graphTypeEnum::LegacyCSR: {
        graph_container.graph_ptr_union.GraphCSRViewDoublePtr =
          std::make_unique<GraphCSRView<int, int, double>>(reinterpret_cast<int*>(offsets),
                                                           reinterpret_cast<int*>(indices),
                                                           reinterpret_cast<double*>(weights),
                                                           num_global_vertices,
                                                           num_global_edges);
        graph_container.graph_type = graphTypeEnum::GraphCSRViewDouble;
        (graph_container.graph_ptr_union.GraphCSRViewDoublePtr)
          ->set_local_data(local_vertices, local_edges, local_offsets);
        (graph_container.graph_ptr_union.GraphCSRViewDoublePtr)
          ->set_handle(const_cast<raft::handle_t*>(&handle));
      } break;
      case graphTypeEnum::LegacyCSC: {
        graph_container.graph_ptr_union.GraphCSCViewDoublePtr =
          std::make_unique<GraphCSCView<int, int, double>>(reinterpret_cast<int*>(offsets),
                                                           reinterpret_cast<int*>(indices),
                                                           reinterpret_cast<double*>(weights),
                                                           num_global_vertices,
                                                           num_global_edges);
        graph_container.graph_type = graphTypeEnum::GraphCSCViewDouble;
        (graph_container.graph_ptr_union.GraphCSCViewDoublePtr)
          ->set_local_data(local_vertices, local_edges, local_offsets);
        (graph_container.graph_ptr_union.GraphCSCViewDoublePtr)
          ->set_handle(const_cast<raft::handle_t*>(&handle));
      } break;
      case graphTypeEnum::LegacyCOO: {
        graph_container.graph_ptr_union.GraphCOOViewDoublePtr =
          std::make_unique<GraphCOOView<int, int, double>>(reinterpret_cast<int*>(offsets),
                                                           reinterpret_cast<int*>(indices),
                                                           reinterpret_cast<double*>(weights),
                                                           num_global_vertices,
                                                           num_global_edges);
        graph_container.graph_type = graphTypeEnum::GraphCOOViewDouble;
        (graph_container.graph_ptr_union.GraphCOOViewDoublePtr)
          ->set_local_data(local_vertices, local_edges, local_offsets);
        (graph_container.graph_ptr_union.GraphCOOViewDoublePtr)
          ->set_handle(const_cast<raft::handle_t*>(&handle));
      } break;
      default: CUGRAPH_FAIL("unsupported graphTypeEnum value"); break;
    }
  }
  return;
}

////////////////////////////////////////////////////////////////////////////////

namespace detail {
template <typename graph_view_t, typename weight_t>
std::pair<size_t, weight_t> call_louvain(raft::handle_t const& handle,
                                         graph_view_t const& graph_view,
                                         void* identifiers,
                                         void* parts,
                                         size_t max_level,
                                         weight_t resolution)
{
  thrust::copy(  // rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
    thrust::device,
    thrust::make_counting_iterator(graph_view.get_local_vertex_first()),
    thrust::make_counting_iterator(graph_view.get_local_vertex_last()),
    reinterpret_cast<typename graph_view_t::vertex_type*>(identifiers));

  return louvain(handle,
                 graph_view,
                 reinterpret_cast<typename graph_view_t::vertex_type*>(parts),
                 max_level,
                 static_cast<weight_t>(resolution));
}

}  // namespace detail

namespace detail {

// Final, fully-templatized call.
template <bool transposed,
          typename return_t,
          typename function_t,
          typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool is_multi_gpu>
return_t call_function(raft::handle_t const& handle,
                       graph_container_t const& graph_container,
                       function_t function)
{
  auto graph =
    create_graph<vertex_t, edge_t, weight_t, transposed, is_multi_gpu>(handle, graph_container);

  return function(handle, graph->view());
}

// Makes another call based on vertex_t and edge_t
template <bool transposed,
          typename return_t,
          typename function_t,
          typename weight_t,
          bool is_multi_gpu>
return_t call_function(raft::handle_t const& handle,
                       graph_container_t const& graph_container,
                       function_t function)
{
  // Since only vertex/edge types (int32,int32), (int32,int64), and
  // (int64,int64) are being supported, explicitely check for those types and
  // ensure (int64,int32) is rejected as unsupported.
  if ((graph_container.vertexType == numberTypeEnum::int32Type) &&
      (graph_container.edgeType == numberTypeEnum::int32Type)) {
    return call_function<transposed,
                         return_t,
                         function_t,
                         int32_t,
                         int32_t,
                         weight_t,
                         is_multi_gpu>(handle, graph_container, function);
  } else if ((graph_container.vertexType == numberTypeEnum::int32Type) &&
             (graph_container.edgeType == numberTypeEnum::int64Type)) {
    return call_function<transposed,
                         return_t,
                         function_t,
                         int32_t,
                         int64_t,
                         weight_t,
                         is_multi_gpu>(handle, graph_container, function);
  } else if ((graph_container.vertexType == numberTypeEnum::int64Type) &&
             (graph_container.edgeType == numberTypeEnum::int64Type)) {
    return call_function<transposed,
                         return_t,
                         function_t,
                         int64_t,
                         int64_t,
                         weight_t,
                         is_multi_gpu>(handle, graph_container, function);
  } else {
    CUGRAPH_FAIL("vertexType/edgeType combination unsupported");
  }
}

// Makes another call based on weight_t
template <bool transposed, typename return_t, typename function_t, bool is_multi_gpu>
return_t call_function(raft::handle_t const& handle,
                       graph_container_t const& graph_container,
                       function_t function)
{
  if (graph_container.weightType == numberTypeEnum::floatType) {
    return call_function<transposed, return_t, function_t, float, transposed>(
      handle, graph_container, function);
  } else if (graph_container.weightType == numberTypeEnum::doubleType) {
    return call_function<transposed, return_t, function_t, double, transposed>(
      handle, graph_container, function);
  } else {
    CUGRAPH_FAIL("weightType unsupported");
  }
}

// Makes another call based on multi_gpu
template <bool transposed, typename return_t, typename function_t>
return_t call_function(raft::handle_t const& handle,
                       graph_container_t const& graph_container,
                       function_t function)
{
  if (graph_container.is_multi_gpu) {
    return call_function<transposed, return_t, function_t, true>(handle, graph_container, function);
  } else {
    return call_function<transposed, return_t, function_t, false>(
      handle, graph_container, function);
  }
}

// Initial call_function() call starts here.
// This makes another call based on transposed
template <typename return_t, typename function_t>
return_t call_function(raft::handle_t const& handle,
                       graph_container_t const& graph_container,
                       function_t function)
{
  if (graph_container.transposed) {
    return call_function<true, return_t, function_t>(handle, graph_container, function);
  } else {
    return call_function<false, return_t, function_t>(handle, graph_container, function);
  }
}

template <typename weight_t>
class louvain_functor {
 public:
  louvain_functor(void* identifiers, void* parts, size_t max_level, weight_t resolution)
    : identifiers_(identifiers), parts_(parts), max_level_(max_level), resolution_(resolution)
  {
  }

  template <typename graph_view_t>
  std::pair<size_t, weight_t> operator()(raft::handle_t const& handle,
                                         graph_view_t const& graph_view)
  {
    return cugraph::louvain(handle,
                            graph_view,
                            reinterpret_cast<typename graph_view_t::vertex_type*>(parts_),
                            max_level_,
                            resolution_);
  }

 private:
  void* identifiers_;  // FIXME: this will be used in a future PR
  void* parts_;
  size_t max_level_;
  weight_t resolution_;
};

}  // namespace detail

// Wrapper for calling Louvain using a graph container
template <typename weight_t>
std::pair<size_t, weight_t> call_louvain(raft::handle_t const& handle,
                                         graph_container_t const& graph_container,
                                         void* identifiers,
                                         void* parts,
                                         size_t max_level,
                                         weight_t resolution)
{
  // LEGACY PATH - remove when migration to graph_t types complete
  if (graph_container.graph_type == graphTypeEnum::GraphCSRViewFloat) {
    graph_container.graph_ptr_union.GraphCSRViewFloatPtr->get_vertex_identifiers(
      static_cast<int32_t*>(identifiers));
    return louvain(handle,
                   *(graph_container.graph_ptr_union.GraphCSRViewFloatPtr),
                   reinterpret_cast<int32_t*>(parts),
                   max_level,
                   static_cast<float>(resolution));
  } else if (graph_container.graph_type == graphTypeEnum::GraphCSRViewDouble) {
    graph_container.graph_ptr_union.GraphCSRViewDoublePtr->get_vertex_identifiers(
      static_cast<int32_t*>(identifiers));
    return louvain(handle,
                   *(graph_container.graph_ptr_union.GraphCSRViewDoublePtr),
                   reinterpret_cast<int32_t*>(parts),
                   max_level,
                   static_cast<double>(resolution));
  }

  // NON-LEGACY PATH
  detail::louvain_functor<weight_t> functor{identifiers, parts, max_level, resolution};

  return detail::call_function<false, std::pair<size_t, weight_t>>(
    handle, graph_container, functor);
}

// Explicit instantiations
template std::pair<size_t, float> call_louvain(raft::handle_t const& handle,
                                               graph_container_t const& graph_container,
                                               void* identifiers,
                                               void* parts,
                                               size_t max_level,
                                               float resolution);

template std::pair<size_t, double> call_louvain(raft::handle_t const& handle,
                                                graph_container_t const& graph_container,
                                                void* identifiers,
                                                void* parts,
                                                size_t max_level,
                                                double resolution);

}  // namespace cython
}  // namespace cugraph
