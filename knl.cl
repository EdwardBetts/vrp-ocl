#ifndef NOTEST
#define MUT_RATE 25
#define MUT_SWAP
#define NUM_TRUCKS 7
#define NUM_COORDS 75
#define CAPACITY 220
#define GROUP_SIZE 256
#define GLOBAL_SIZE 256
#define MAX_PER_ROUTE 12
#define K_OPT 2
#define ROUTE_STOPS (75)
#endif

typedef struct sort_info {
    // length of route - used to compare
    float route_length;
    // index of route in parent/children (could be either)
    __global const uint* idx;
} sort_t;

typedef struct point_info {
    int first_index;
    int second_index;
    float distance;
} point_info_t ;

typedef struct point {
    int first;
    int second;
} point_t;

typedef struct route {
    uint* subroute;
    float best_subroute_length, cur_subroute_length;
    uint route_begin, route_end, length;
} route_t;

/*
 *  Random number generator
 *  source: http://cas.ee.ic.ac.uk/people/dt10/research/rngs-gpu-mwc64x.html
 */
uint MWC64X(__global uint2* const state)
{
    enum _dummy { A=4294883355U };
    //unsigned int A = 4294883355U ;
    uint x=(*state).x, c=(*state).y;  // Unpack the state
    uint res=x^c;                     // Calculate the result
    uint hi=mul_hi(x,A);              // Step the RNG
    x=x*A+c;
    c=hi+(x<c);
    *state=(uint2)(x,c);               // Pack the state back up
    return res;                       // Return the next result
}

/**************************************/

/*
 *  Returns euclidean distance between two points
 */
float euclideanDistance
(point_t first, point_t second)
{
    /*
    float x1, y1, x2, y2;

    x1 = first.first;
    y1 = first.second;
    x2 = second.first;
    y2 = second.second;

    // native is a bit quicker?
    return native_sqrt(((x2-x1)*(x2-x1) + (y2-y1)*(y2-y1)));
    */

    const float2 a = (float2)(first.first,first.second);
    const float2 b = (float2)(second.first,second.second);

    return distance(a, b);
}

/*
 *  Takes global pointers to chromosomes, node coordinates, node demands, and a
 *  pointer to route_starts which is global storage holding the positions in
 *  each chromosome where the beginning of the mini subroutes start.
 *
 *  The subroutes are calculated based on the demand of the nodes - go through
 *  the chromosome until the demand for the nodes visited surpasses the
 *  capacity of the truck, then mark it as the split to the next subroute and
 *  start counting again.
 *
 *  For example, for a route 1 2 3 4 5 6 7 8 9, the subroute starts might be at
 *  position 0, 4, and 7. This route is split up into subroutes 1-2-3-4, 5-6-7,
 *  and 8-9.
 */
void findRouteStarts
(__global   const uint*          __restrict chromosomes,
 __constant const point_t* const __restrict node_coords,
 __constant const point_t* const __restrict node_demands,
 __global         int*           __restrict route_starts)
{
    uint group_id = get_group_id(0);
    uint loc_id = get_local_id(0);

    // counters
    uint ii, rr;

    uint cur_capacity = 0;

    // increment pointers to point to this thread's chromosome values
    chromosomes  += GROUP_SIZE * ROUTE_STOPS * group_id + loc_id * ROUTE_STOPS;
    route_starts += GROUP_SIZE * NUM_TRUCKS  * group_id + loc_id * NUM_TRUCKS;

    // stops in current route - initially 0
    uint stops_taken = 0;

    // stuff currently in truck - 0 at first
    cur_capacity = 0;
    //cur_capacity = node_demands[0].second; // XXX why was this initialised?

    for(ii = 0; ii < NUM_TRUCKS; ii++)
    {
        route_starts[ii] = 0;
    }

    rr = 1;

    for(ii = 0; ii < ROUTE_STOPS; ii++)
    {
        // ignore depot stops - go back to depot when its full / too many things in route
        while(chromosomes[ii] == 0)
        {
            ii++;
            if(ii >= ROUTE_STOPS) break;
        }

        cur_capacity += node_demands[chromosomes[ii]].second;

        // if adding the next node will go over capacity
        if(cur_capacity > CAPACITY || ++stops_taken >= MAX_PER_ROUTE)
        {
            stops_taken = 0;
            cur_capacity = node_demands[chromosomes[ii]].second;

            route_starts[++rr] = ii;
        }
    }

    // route_starts[0] contains number of sub routes
    // route_starts[1] always contains 0 - the start of the first route
    route_starts[0] = rr;
}

/************************/

int routeDemand
(                 uint*    const __restrict route,
                  uint                      route_length,
 __constant const point_t* const __restrict node_demands)
{
    uint total, ii;
    total = 0;

    for(ii = 0; ii < route_length; ii++)
    {
        total += node_demands[route[ii]].second;
    }

    return total;
}

float totalRouteLength
(__global   const uint*    const __restrict chromosome,
 __constant const point_t* const __restrict node_coords,
 __constant const point_t* const __restrict node_demands)
{
    uint ii;
    uint jj;

    uint cur_capacity = 0;
    // for calculating length of route
    float total_distance = 0.0f;

    // add distance to first node
    total_distance += euclideanDistance(
        node_coords[0],
        node_coords[chromosome[0]]);

    // capaciy of first node
    cur_capacity += node_demands[chromosome[0]].second;

    // stops in current route
    uint stops_taken = 1;

    for(ii = 0, jj = 1;
    ii < ROUTE_STOPS - 1 && jj < ROUTE_STOPS;
    ii++, jj++)
    {
        cur_capacity += node_demands[chromosome[jj]].second;

        // if adding the next node will go over capacity
        // add distance to and from node
        if(cur_capacity > CAPACITY || ++stops_taken >= MAX_PER_ROUTE)
        {
            stops_taken = 1;

            total_distance += euclideanDistance(
                node_coords[chromosome[ii]],
                node_coords[0]);
            total_distance += euclideanDistance(
                node_coords[0],
                node_coords[chromosome[jj]]);

            cur_capacity = node_demands[chromosome[jj]].second;
        }
        else
        {
            total_distance += euclideanDistance(
                node_coords[chromosome[ii]],
                node_coords[chromosome[jj]]);
        }
    }

    // add distance to last node
    total_distance += euclideanDistance(
        node_coords[chromosome[ROUTE_STOPS - 1]],
        node_coords[0]);

    return total_distance;
}

float routeLength
(__global   const uint*    const __restrict chromosome,
 __constant const point_t* const __restrict node_coords)
{
    uint ii;
    float route_length = 0.0f;

    for(ii = 0; ii < ROUTE_STOPS; ii++)
    {
        route_length += euclideanDistance(
            node_coords[chromosome[ii]],
            node_coords[chromosome[ii+1]]);
    }

    return route_length;
}

__kernel void fitness
(__global   const uint *         __restrict chromosomes,
 __global         float *   const __restrict results,
 __constant const point_t * const __restrict node_coords,
 __constant const point_t * const __restrict node_demands,
 __global         int *           __restrict route_starts)
{
    const uint glob_id = get_global_id(0);
    const uint loc_id = get_local_id(0);
    const uint group_id = get_group_id(0);

    // offset to this work item
    chromosomes += GROUP_SIZE * group_id * ROUTE_STOPS + loc_id * ROUTE_STOPS;

    results[glob_id] = totalRouteLength(chromosomes, node_coords, node_demands);
}

/************************/

/*
*   Modified version of bitonic sort
*   source: http://www.bealto.com/gpu-sorting_parallel-merge-local.html
*/

__kernel void ParallelBitonic_NonElitist
(__global const float * __restrict route_lengths,
 __global const uint *  __restrict chromosomes,
 __global       uint *  __restrict output)
{
    int ii = get_local_id(0); // index in workgroup
    int group_id = get_group_id(0) ;
    int loc_id = get_local_id(0) ;

    __local sort_t aux[GROUP_SIZE * 2];

    route_lengths += group_id * GROUP_SIZE;

    // uses the current thread index and length of route to sort, then whatever
    // thread ends up with it in its index in the local array copies it back out to the output
    sort_t sort_pair;
    // need to be twice the group size because this works on twice the range
    sort_pair.route_length = route_lengths[loc_id];
    // idx is the location of the current chromosome, relative to beginning of work group
    sort_pair.idx = chromosomes + GROUP_SIZE * ROUTE_STOPS * group_id + loc_id * ROUTE_STOPS;
    aux[loc_id] = sort_pair;

    // Load block in AUX[WG]
    aux[ii] = sort_pair;
    barrier(CLK_LOCAL_MEM_FENCE); // make sure AUX is entirely up to date

    // Loop on sorted sequence length
    for (int length = 1; length < GROUP_SIZE; length <<= 1)
    {
        bool direction = ((ii & (length << 1)) != 0); // direction of sort: 0=asc, 1=desc
        // Loop on comparison distance (between keys)
        for (int inc = length; inc > 0; inc >>= 1)
        {
            #define getKey(x) (x.route_length)
            int j = ii ^ inc; // sibling to compare
            sort_t iData = aux[ii];
            uint iKey = getKey(iData);
            sort_t jData = aux[j];
            uint jKey = getKey(jData);
            bool smaller = (jKey < iKey) || ( jKey == iKey && j < ii );
            bool swap = smaller ^ (j < ii) ^ direction;
            barrier(CLK_LOCAL_MEM_FENCE);
            aux[ii] = (swap)?jData:iData;
            barrier(CLK_LOCAL_MEM_FENCE);
        }
    }

    uint kk;

    output += GROUP_SIZE * ROUTE_STOPS * group_id + loc_id * ROUTE_STOPS;
    __global const uint* input = aux[loc_id].idx;
    for(kk = 0; kk < ROUTE_STOPS; kk++)
    {
        output[kk] = input[kk];
    }
}

__kernel void ParallelBitonic_Elitist
(__global const float * __restrict route_lengths,
 __global const uint *  __restrict parents,
 __global const uint *  __restrict children,
 __global       uint *  __restrict output)
{
    int ii = get_local_id(0); // index in workgroup
    int group_id = get_group_id(0) ;
    int loc_id = get_local_id(0) ;
    int loc_div;

    __local sort_t aux[GROUP_SIZE * 4];

    // offset to this work group
    route_lengths += group_id * GROUP_SIZE;

    // uses the current thread index and length of route to sort, then whatever
    // thread ends up with it in its index in the local array copies it back out to the output
    sort_t sort_pair;

    // if an even item in the work group
    if(loc_id % 2 == 0)
    {
        // then use this to access children
        loc_div = loc_id / 2;
        sort_pair.idx = children + GROUP_SIZE * ROUTE_STOPS * group_id + loc_div * ROUTE_STOPS;
        sort_pair.route_length = route_lengths[loc_div];
    }
    else
    {
        // then use this to access parents
        loc_div = (loc_id - 1) / 2;
        sort_pair.idx = parents + GROUP_SIZE * ROUTE_STOPS * group_id + loc_div * ROUTE_STOPS;
        sort_pair.route_length = route_lengths[loc_div + GLOBAL_SIZE];
    }

    aux[loc_id] = sort_pair;

    barrier(CLK_LOCAL_MEM_FENCE); // make sure AUX is entirely up to date

    // Loop on sorted sequence length
    for (int length = 1; length < get_local_size(0); length <<= 1)
    {
        bool direction = ((ii & (length << 1)) != 0); // direction of sort: 0=asc, 1=desc
        // Loop on comparison distance (between keys)
        for (int inc = length; inc > 0; inc >>= 1)
        {
            #define getKey(x) (x.route_length)
            int j = ii ^ inc; // sibling to compare
            sort_t iData = aux[ii];
            uint iKey = getKey(iData);
            sort_t jData = aux[j];
            uint jKey = getKey(jData);
            bool smaller = (jKey < iKey) || ( jKey == iKey && j < ii );
            bool swap = smaller ^ (j < ii) ^ direction;
            barrier(CLK_LOCAL_MEM_FENCE);
            aux[ii] = (swap)?jData:iData;
            barrier(CLK_LOCAL_MEM_FENCE);
        }
    }

    // copy back only the first half
    if(loc_id < GROUP_SIZE)
    {
        output += GROUP_SIZE * ROUTE_STOPS * group_id + loc_id * ROUTE_STOPS;
        __global const uint* input = aux[loc_id].idx;
        for(ii = 0; ii < ROUTE_STOPS; ii++)
        {
            output[ii] = input[ii];
        }
    }
}

/**************************************/

// dummy - do no TSP at all
__kernel void noneTSP
(__global uint* __restrict chromosomes,
 __global int* __restrict route_starts,
 __constant const point_t* const __restrict node_coords,
 __constant const point_t* const __restrict node_demands,
 __global uint2* const __restrict state)
{
    ;
}

__kernel void cx
(__global const uint*          __restrict parents,
 __global       uint*          __restrict children,
 __global       uint*          __restrict route_lengths,
 __global       int *          __restrict route_starts,
 __constant     point_t* const __restrict node_coords,
 __constant     point_t* const __restrict node_demands,
 __global       uint2*   const __restrict state,
 unsigned int lower_bound, unsigned int upper_bound)
{
    uint glob_id = get_global_id(0);
    uint group_id = get_group_id(0);
    uint loc_id = get_local_id(0);
    uint ii, jj, cc;

    // offset to this work group
    parents += GROUP_SIZE * ROUTE_STOPS * group_id;

    // randomly choose
    uint other_parent;
    do
    {
        other_parent = MWC64X(&state[glob_id]) % GROUP_SIZE;
    }
    while(other_parent == loc_id);

    // offset to this item
    __global const uint* parent_1 = parents + loc_id * ROUTE_STOPS;

    // other parent
    __global const uint* parent_2 = parents + other_parent * ROUTE_STOPS;

    // at the end, will hold array of numbers form 1-num cycles
    char cycles[ROUTE_STOPS];
    // to see which ones have been visited
    char vis_mask[ROUTE_STOPS];

    // reset
    for(jj = 0; jj < ROUTE_STOPS; jj++)
    {
        cycles[jj] = 0;
        vis_mask[jj] = 0;
    }

    // beginning of first cycle
    uint target = lower_bound;

    // next index in loop
    uint next_idx;

    // cycle count
    cc = 1;

    do
    {
        // find the index of target in the first parent
        for(jj = 0; jj < ROUTE_STOPS; jj++)
        {
            if(parent_1[jj] == target)
            {
                next_idx = jj;
                break;
            }
        }

        // it has already been in the current cycle - back to beginning
        if(vis_mask[next_idx])
        {
            for(jj = 0; jj < ROUTE_STOPS; jj++)
            {
                if(vis_mask[jj])
                {
                    // set node index in cycle to indicate
                    // which cycle number it was in
                    cycles[jj] = cc;
                }
                vis_mask[jj] = 0;
            }

            bool end = true;
            // see if they've all been added
            for(jj = 0; jj < ROUTE_STOPS; jj++)
            {
                // if even a single one remains, dont finish
                if(!cycles[jj])
                {
                    end = false;
                    break;
                }
            }

            // if its going to end, next bit will loop infinitely
            if(end)
            {
                break;
            }

            // find next that isn't already in a route
            do
            {
                target = MWC64X(&state[glob_id]) % ROUTE_STOPS;
            }
            while(cycles[target]);

            target = parent_2[target];

            // increment cycle number
            cc++;
            //if(cc>6)break;
        }
        else
        {
            vis_mask[next_idx] = 1;

            target = parent_2[next_idx];
        }
    }
    // while it hasn't been told to end
    while(1);

    // copy into child first - dont mess up parent if elitist sorting
    uint child[ROUTE_STOPS];

    // flip parent between cycles
    bool parent_flip = false;

    // cycle numbers
    for(ii = 1; ii <= cc; ii++)
    {
        // go through cycle, picking from one parent or another
        for(jj = 0; jj < ROUTE_STOPS; jj++)
        {
            // if the current cycle contained this idx
            if(cycles[jj] == ii)
            {
                child[jj] = parent_flip ? parent_1[jj] : parent_2[jj];
            }
        }

        // choose from different parent for each cycle
        parent_flip = !parent_flip;
    }

    uint tmp_val;
    #define SWAP(x, y) tmp_val=x; x=y; y=tmp_val;

    // mutate with MUT_RATE% chance
    if(MWC64X(&state[glob_id]) % 100 < MUT_RATE)
    {
        #if defined(MUT_REVERSE)

        // reverse a random section of the chromosome
        uint ll, uu, range;

        ll = MWC64X(&state[glob_id]) % ROUTE_STOPS;
        range = MWC64X(&state[glob_id]) % (ROUTE_STOPS - ll);
        uu = ll + range;

        for(; ll < uu; ll++, uu--)
        {
            SWAP(child[ll], child[uu]);
        }

        #elif defined(MUT_SWAP)

        uint ll1, uu1, ll2, uu2, range;

        /*
         *  number of values to swap
         *
         *  calculated like:
         *
         *      <--range-->     <--range-->
         *  [------------------------------------]
         *      ^         ^     ^         ^
         *     ll1       uu1   ll2       uu2
         *
         *  ranges will not overlap
         */

        // value to start bottom end of swap at - skewed towards bottom end
        ll1 = MWC64X(&state[glob_id]) % ROUTE_STOPS;
        // FIXME not working - hanging
        //ll1 = MWC64X(&state[glob_id]) % (MWC64X(&state[glob_id]) % ROUTE_STOPS);

        // range is random length smaller than that left...
        range = MWC64X(&state[glob_id]) % (ROUTE_STOPS - ll1);
        // ...and enough to fit 2 ranges in to swap
        range /= 2;

        // uu1 calculated from range
        uu1 = ll1 + range;

        // calculate ll2 as some position long enough to fit the swap range in
        // after
        ll2 = MWC64X(&state[glob_id]) % (ROUTE_STOPS - (uu1 + range));
        // and its after uu1
        ll2 += uu1;

        // swap range
        for(ii = 0; ii < range; ii++)
        {
            SWAP(child[ll1+ii], child[ll2+ii]);
        }

        #else

        #error "No mutation strategy specified"

        #endif
    }

    // increment children to point to this threads chromosome child
    children += GROUP_SIZE * ROUTE_STOPS * group_id + loc_id * ROUTE_STOPS;

    // copy into children
    for(ii = 0; ii < ROUTE_STOPS; ii++)
    {
        children[ii] = child[ii];
    }
}

/************************/

float subrouteLength
(uint* const __restrict route,
 int route_stops,
 __constant point_t* const __restrict node_coords)
{
    uint ii;
    float route_length = 0.0f;

    for(ii = 0; ii < route_stops; ii++)
    {
        route_length += euclideanDistance(
            node_coords[route[ii]],
            node_coords[route[ii+1]]);
    }

    return route_length;
}

__kernel void simpleTSP
(__global uint* __restrict chromosomes,
 __global int* __restrict route_starts,
 __constant const point_t* const __restrict node_coords,
 __constant const point_t* const __restrict node_demands,
 __global uint2* const __restrict state)
{
    uint glob_id = get_global_id(0);
    uint loc_id = get_local_id(0);
    uint group_id = get_group_id(0);

    // counters
    uint ii, jj, kk, oo;

    findRouteStarts(chromosomes, node_coords, node_demands, route_starts);

    // offset
    chromosomes += GROUP_SIZE * group_id * ROUTE_STOPS + loc_id * ROUTE_STOPS;
    route_starts += GROUP_SIZE * group_id * NUM_TRUCKS + loc_id * NUM_TRUCKS;

    // copy chromosome into private memory
    uint chromosome[ROUTE_STOPS];
    for(ii = 0; ii < ROUTE_STOPS; ii++)
    {
        chromosome[ii] = chromosomes[ii];
    }

    // swap two values
    uint tmp_val;
    #define SWAP(x, y) tmp_val=x; x=y; y=tmp_val;

    // best length of route
    float best_subroute_length;
    float cur_subroute_length;

    uint num_routes = route_starts[0];
    // for each mini route
    for(ii = 1; ii < num_routes; ii++)
    {
        // beginning and end of current route, including depot stops
        uint route_begin = route_starts[ii];

        // current route to look at
        uint* const current_subroute = chromosome + route_begin;

        uint route_end;
        if(ii < num_routes - 1)
        {
            route_end = route_starts[ii + 1];
        }
        else
        {
            route_end = ROUTE_STOPS;
        }

        // length of current route
        uint route_length = route_end - route_begin;

        // best for this route
        best_subroute_length = subrouteLength(current_subroute,
                                              route_length,
                                              node_coords);

        // for each item in the current sub route pointed to by current_subroute
        for(jj = 1; jj < route_length; jj++)
        {
            // for each pair of routes in total route
            for(kk = jj + 1; kk < route_length; kk++)
            {
                if(jj != kk
                && current_subroute[jj] != 0
                && current_subroute[kk] != 0)
                {
                    // swap and see if its good
                    SWAP(current_subroute[jj], current_subroute[kk]);
                    cur_subroute_length = subrouteLength(current_subroute,
                                                         route_length,
                                                         node_coords);

                    if(cur_subroute_length < best_subroute_length)
                    {
                        best_subroute_length = cur_subroute_length;
                    }
                    else
                    {
                        // swap back if not
                        SWAP(current_subroute[jj], current_subroute[kk]);
                    }
                }
            }
        }
    }

    // copy chromosome back
    for(ii = 0; ii < ROUTE_STOPS; ii++)
    {
        chromosomes[ii] = chromosome[ii];
    }
}

/************************/

__kernel void foreignExchange
(__global uint* __restrict chromosomes,
 __global uint2* const __restrict state)
{
    uint loc_id = get_local_id(0);
    uint group_id = get_group_id(0);
    uint num_groups = get_num_groups(0);

    // the best item from each group gets swapped
    if(loc_id == 0 && group_id < num_groups / 2)
    {
        // best in this work group
        __global uint* local_chrom = chromosomes
            + GROUP_SIZE * group_id * ROUTE_STOPS;

        // best in the other work group
        __global uint* foreign_chrom = chromosomes
            + GROUP_SIZE * (group_id + (num_groups / 2)) * ROUTE_STOPS;

        int rand_offset = MWC64X(&state[get_global_id(0)]) % GROUP_SIZE;

        foreign_chrom += ROUTE_STOPS * rand_offset;

        uint tmp_val;
        #define SWAP(x, y) tmp_val=x; x=y; y=tmp_val;

        uint ii;
        for(ii = 0; ii < ROUTE_STOPS; ii++)
        {
            SWAP(local_chrom[ii], foreign_chrom[ii]);
        }
    }
}

