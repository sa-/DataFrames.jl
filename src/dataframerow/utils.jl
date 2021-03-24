# Rows grouping.
# Maps row contents to the indices of all the equal rows.
# Used by groupby(), join(), nonunique()
struct RowGroupDict{T<:AbstractDataFrame}
    "source data table"
    df::T
    "row hashes (optional, can be empty)"
    rhashes::Vector{UInt}
    "hashindex -> index of group-representative row (optional, can be empty)"
    gslots::Vector{Int}
    "group index for each row"
    groups::Vector{Int}
    "permutation of row indices that sorts them by groups"
    rperm::Vector{Int}
    "starts of ranges in rperm for each group"
    starts::Vector{Int}
    "stops of ranges in rperm for each group"
    stops::Vector{Int}
end

# "kernel" functions for hashrows()
# adjust row hashes by the hashes of column elements
function hashrows_col!(h::Vector{UInt},
                       n::Vector{Bool},
                       v::AbstractVector{T},
                       rp::Nothing,
                       firstcol::Bool) where T
    tforeach(eachindex(h), basesize=1_000_000) do i
        @inbounds begin
            el = v[i]
            h[i] = hash(el, h[i])
            if length(n) > 0
                n[i] |= ismissing(el)
            end
        end
    end
    h
end

# should give the same hash as AbstractVector{T}
function hashrows_col!(h::Vector{UInt},
                       n::Vector{Bool},
                       v::AbstractVector,
                       rp::Any,
                       firstcol::Bool)
    # When hashing the first column, no need to take into account previous hash,
    # which is always zero
    # also when the number of values in the pool is more than half the length
    # of the vector avoid using this path. 50% is roughly based on benchmarks
    if firstcol && Int64(2) * length(rp) < length(v)
        ra = DataAPI.refarray(v)
        firp = firstindex(rp)
        fira = firstindex(ra)

        hashes = Vector{UInt}(undef, length(rp))
        tforeach(eachindex(hashes), basesize=1_000_000) do i
            @inbounds hashes[i] = hash(rp[i+firp-1])
        end

        # here we rely on the fact that `DataAPI.refpool` has a continuous
        # block of indices
        tforeach(eachindex(h), basesize=1_000_000) do i
            @inbounds ref = ra[i+fira-1]
            @inbounds h[i] = hashes[ref+1-firp]
        end
    else
        tforeach(eachindex(h, v), basesize=1_000_000) do i
            @inbounds h[i] = hash(v[i], h[i])
        end
    end
    # Doing this step separately is faster, as it would disable SIMD above
    if eltype(v) >: Missing && length(n) > 0
        n .|= ismissing.(v)
    end
    h
end

# Calculate the vector of `df` rows hash values.
function hashrows(cols::Tuple{Vararg{AbstractVector}}, skipmissing::Bool)
    len = length(cols[1])
    rhashes = zeros(UInt, len)
    missings = fill(false, skipmissing ? len : 0)
    for (i, col) in enumerate(cols)
        rp = DataAPI.refpool(col)
        hashrows_col!(rhashes, missings, col, rp, i == 1)
    end
    return (rhashes, missings)
end

# table columns are passed as a tuple of vectors to ensure type specialization
isequal_row(cols::Tuple{AbstractVector}, r1::Int, r2::Int) =
    isequal(cols[1][r1], cols[1][r2])
isequal_row(cols::Tuple{Vararg{AbstractVector}}, r1::Int, r2::Int) =
    isequal(cols[1][r1], cols[1][r2]) && isequal_row(Base.tail(cols), r1, r2)

isequal_row(cols1::Tuple{AbstractVector}, r1::Int, cols2::Tuple{AbstractVector}, r2::Int) =
    isequal(cols1[1][r1], cols2[1][r2])
isequal_row(cols1::Tuple{Vararg{AbstractVector}}, r1::Int,
            cols2::Tuple{Vararg{AbstractVector}}, r2::Int) =
    isequal(cols1[1][r1], cols2[1][r2]) &&
        isequal_row(Base.tail(cols1), r1, Base.tail(cols2), r2)

# IntegerRefarray and IntegerRefPool are two complementary view types that allow
# wrapping arrays with Union{Real, Missing} eltype to satisfy the DataAPI.refpool
# and DataAPI.refarray API when calling row_group_slots.
# IntegerRefarray converts values to Int and replaces missing with an integer
# (set by the caller to the maximum value + 1)
# IntegerRefPool subtracts the minimum value - 1 and replaces back the maximum
# value + 1 to missing. This ensures all values are in 1:length(refpool), while
# row_group_slots knows the number of (potential) groups via length(refpool)
# and is able to skip missing values when skipmissing=true

struct IntegerRefarray{T<:AbstractArray} <: AbstractVector{Int}
    x::T
    offset::Int
    replacement::Int
end

Base.size(x::IntegerRefarray) = size(x.x)
Base.axes(x::IntegerRefarray) = axes(x.x)
Base.IndexStyle(::Type{<:IntegerRefarray{T}}) where {T} = Base.IndexStyle(T)
@inline function Base.getindex(x::IntegerRefarray, i)
    @boundscheck checkbounds(x.x, i)
    @inbounds v = x.x[i]
    if eltype(x.x) >: Missing && v === missing
        return x.replacement
    else
        # Overflow is guaranteed not to happen by checks before calling the constructor
        return Int(v - x.offset)
    end
end

struct IntegerRefpool{T<:Union{Int, Missing}} <: AbstractVector{T}
    max::Int
    function IntegerRefpool{T}(max::Integer) where T<:Union{Int, Missing}
        @assert max < typemax(Int) # to store missing values as max + 1
        new{T}(max)
    end
end

Base.size(x::IntegerRefpool{T}) where {T} = (x.max + (T >: Missing),)
Base.axes(x::IntegerRefpool{T}) where {T} = (Base.OneTo(x.max + (T >: Missing)),)
Base.IndexStyle(::Type{<:IntegerRefpool}) = Base.IndexLinear()
@inline function Base.getindex(x::IntegerRefpool{T}, i::Real) where T
    @boundscheck checkbounds(x, i)
    if T >: Missing && i == x.max + 1
        return missing
    else
        return Int(i)
    end
end
Base.allunique(::IntegerRefpool) = true
Base.issorted(::IntegerRefpool) = true

function refpool_and_array(x::AbstractArray)
    refpool = DataAPI.refpool(x)
    refarray = DataAPI.refarray(x)

    if refpool !== nothing
        return refpool, refarray
    elseif x isa AbstractArray{<:Union{Real, Missing}} &&
        all(v -> ismissing(v) | isinteger(v), x) &&
        !isempty(skipmissing(x))
        minval, maxval = extrema(skipmissing(x))
        ngroups = big(maxval) - big(minval) + 1
        # Threshold chosen with the same rationale as the row_group_slots refpool method:
        # refpool approach is faster but we should not allocate too much memory either
        # We also have to avoid overflow, including with ngroups + 1 for missing values
        # (note that it would be possible to allow minval and maxval to be outside of the
        # range supported by Int by adding a type parameter for minval to IntegerRefarray)
        if typemin(Int) < minval <= maxval < typemax(Int) &&
            ngroups + 1 <= Int64(2) * length(x) <= typemax(Int)
            T = eltype(x) >: Missing ? Union{Int, Missing} : Int
            refpool′ = IntegerRefpool{T}(Int(ngroups))
            refarray′ = IntegerRefarray(x, Int(minval) - 1, Int(ngroups) + 1)
            return refpool′, refarray′
        end
    end
    return nothing, nothing
end

# Helper function for RowGroupDict.
# Returns a tuple:
# 1) the highest group index in the `groups` vector
# 2) vector of row hashes (may be empty if hash=Val(false))
# 3) slot array for a hash map, non-zero values are
#    the indices of the first row in a group
# 4) whether groups are already sorted
# Optional `groups` vector is set to the group indices of each row (starting at 1)
# With skipmissing=true, rows with missing values are attributed index 0.
function row_group_slots(cols::Tuple{Vararg{AbstractVector}},
                         hash::Val = Val(true),
                         groups::Union{Vector{Int}, Nothing} = nothing,
                         skipmissing::Bool = false,
                         sort::Bool = false)::Tuple{Int, Vector{UInt}, Vector{Int}, Bool}
    rpa = refpool_and_array.(cols)
    refpools = first.(rpa)
    refarrays = last.(rpa)
    row_group_slots(cols, refpools, refarrays, hash, groups, skipmissing, sort)
end

# Generic fallback method based on open adressing hash table
function row_group_slots(cols::Tuple{Vararg{AbstractVector}},
                         refpools::Any,  # Ignored
                         refarrays::Any, # Ignored
                         hash::Val = Val(true),
                         groups::Union{Vector{Int}, Nothing} = nothing,
                         skipmissing::Bool = false,
                         sort::Bool = false)::Tuple{Int, Vector{UInt}, Vector{Int}, Bool}
    @assert groups === nothing || length(groups) == length(cols[1])
    rhashes, missings = hashrows(cols, skipmissing)
    # inspired by Dict code from base cf. https://github.com/JuliaData/DataTables.jl/pull/17#discussion_r102481481
    # but using open addressing with a table with at least 5/4 as many slots as rows
    # (rounded up to nearest power of 2) to avoid performance degradation
    # in a corner case of groups having exactly one row
    sz = max(1 + ((5 * length(rhashes)) >> 2), 16)
    sz = 1 << (8 * sizeof(sz) - leading_zeros(sz - 1))
    @assert 4 * sz >= 5 * length(rhashes)
    szm1 = sz-1
    gslots = zeros(Int, sz)
    # If missings are to be skipped, they will all go to group 0,
    # which will be removed by functions down the stream
    ngroups = 0
    @inbounds for i in eachindex(rhashes)
        # find the slot and group index for a row
        slotix = rhashes[i] & szm1 + 1
        # Use -1 for non-missing values to catch bugs if group is not found
        gix = skipmissing && missings[i] ? 0 : -1
        probe = 0
        if !skipmissing || !missings[i]
            while true
                g_row = gslots[slotix]
                if g_row == 0 # unoccupied slot, current row starts a new group
                    gslots[slotix] = i
                    gix = ngroups += 1
                    break
                elseif rhashes[i] == rhashes[g_row] # occupied slot, check if miss or hit
                    if isequal_row(cols, i, g_row) # hit
                        gix = groups !== nothing ? groups[g_row] : 0
                        break
                    end
                end
                slotix = slotix & szm1 + 1 # check the next slot
                probe += 1
                @assert probe < sz
            end
        end
        if groups !== nothing
            groups[i] = gix
        end
    end
    return ngroups, rhashes, gslots, false
end

# Optimized method for arrays for which DataAPI.refpool is defined and returns an AbstractVector
function row_group_slots(cols::NTuple{N, AbstractVector},
                         refpools::NTuple{N, AbstractVector},
                         refarrays::NTuple{N,
                             Union{AbstractVector{<:Real},
                                   Missings.EachReplaceMissing{
                                       <:AbstractVector{<:Union{Real, Missing}}}}},
                         hash::Val{false},
                         groups::Union{Vector{Int}, Nothing} = nothing,
                         skipmissing::Bool = false,
                         sort::Bool = false)::Tuple{Int, Vector{UInt}, Vector{Int}, Bool} where N
    # Computing neither hashes nor groups isn't very useful,
    # and this method needs to allocate a groups vector anyway
    @assert groups !== nothing && all(col -> length(col) == length(groups), cols)

    missinginds = map(refpools) do refpool
        eltype(refpool) >: Missing ?
            something(findfirst(ismissing, refpool), lastindex(refpool)+1) : lastindex(refpool)+1
    end

    # If skipmissing=true, rows with missings all go to group 0,
    # which will be removed by functions down the stream
    ngroupstup = map(refpools, missinginds) do refpool, missingind
        len = length(refpool)
        if skipmissing && missingind <= lastindex(refpool)
            return len - 1
        else
            return len
        end
    end
    ngroups = prod(ngroupstup)

    # Fall back to hashing if there would be too many empty combinations
    # or if the pool does not contain only unique values
    # The first check ensures the computation of ngroups did not overflow.
    # The rationale for the 2 threshold is that while the fallback method is always slower,
    # it allocates a hash table of size length(groups) instead of the remap vector
    # of size ngroups (i.e. the number of possible combinations) in this method:
    # so it makes sense to allocate more memory for better performance,
    # but it needs to remain reasonable compared with the size of the data frame.
    anydups = !all(allunique, refpools)
    if prod(big.(ngroupstup)) > typemax(Int) ||
       ngroups > Int64(2) * length(groups) ||
       anydups
        # In the simplest case, we can work directly with the reference codes
        newcols = (skipmissing && any(refpool -> eltype(refpool) >: Missing, refpools)) ||
                  !(refarrays isa NTuple{<:Any, AbstractVector}) ||
                  sort ||
                  anydups ? cols : refarrays
        return invoke(row_group_slots,
                      Tuple{Tuple{Vararg{AbstractVector}}, Any, Any, Val,
                            Union{Vector{Int}, Nothing}, Bool, Bool},
                      newcols, refpools, refarrays, hash, groups, skipmissing, sort)
    end

    seen = fill(false, ngroups)
    strides = (cumprod(collect(reverse(ngroupstup)))[end-1:-1:1]..., 1)::NTuple{N, Int}
    firstinds = map(firstindex, refpools)
    if sort
        nminds = map(refpools, missinginds) do refpool, missingind
            missingind > lastindex(refpool) ?
                eachindex(refpool) : setdiff(eachindex(refpool), missingind)
        end
        if skipmissing
            sorted = all(issorted(view(refpool, nmind))
                         for (refpool, nmind) in zip(refpools, nminds))
        else
            sorted = all(issorted, refpools)
        end
    else
        sorted = false
    end
    if sort && !sorted
        # Compute vector mapping missing to -1 if skipmissing=true
        refmaps = map(cols, refpools, missinginds, nminds) do col, refpool, missingind, nmind
            refmap = collect(0:length(refpool)-1)
            if skipmissing
                fi = firstindex(refpool)
                if missingind <= lastindex(refpool)
                    refmap[missingind-fi+1] = -1
                    refmap[missingind-fi+2:end] .-= 1
                end
                if sort
                    perm = sortperm(view(refpool, nmind))
                    invpermute!(view(refmap, nmind .- fi .+ 1), perm)
                end
            elseif sort
                # collect is needed for CategoricalRefPool
                invpermute!(refmap, sortperm(collect(refpool)))
            end
            refmap
        end
        tforeach(eachindex(groups), basesize=1_000_000) do i
            @inbounds begin
                local refs_i
                let i=i # Workaround for julia#15276
                    refs_i = map(c -> c[i], refarrays)
                end
                vals = map((m, r, s, fi) -> m[r-fi+1] * s, refmaps, refs_i, strides, firstinds)
                j = sum(vals) + 1
                # x < 0 happens with -1 in refmap, which corresponds to missing
                if skipmissing && any(x -> x < 0, vals)
                    j = 0
                else
                    seen[j] = true
                end
                groups[i] = j
            end
        end
    else
        tforeach(eachindex(groups), basesize=1_000_000) do i
            @inbounds begin
                local refs_i
                let i=i # Workaround for julia#15276
                    refs_i = map(refarrays, missinginds) do ref, missingind
                        r = Int(ref[i])
                        if skipmissing
                            return r == missingind ? -1 : (r > missingind ? r-1 : r)
                        else
                            return r
                        end
                    end
                end
                vals = map((r, s, fi) -> (r-fi) * s, refs_i, strides, firstinds)
                j = sum(vals) + 1
                # x < 0 happens with -1, which corresponds to missing
                if skipmissing && any(x -> x < 0, vals)
                    j = 0
                else
                    seen[j] = true
                end
                groups[i] = j
            end
        end
    end
    # If some groups are unused, compress group indices to drop them
    # sum(seen) is faster than all(seen) when not short-circuiting,
    # and short-circuit would only happen in the slower case anyway
    if sum(seen) < length(seen)
        oldngroups = ngroups
        remap = zeros(Int, ngroups)
        ngroups = 0
        @inbounds for i in eachindex(remap, seen)
            ngroups += seen[i]
            remap[i] = ngroups
        end
        @inbounds for i in eachindex(groups)
            gix = groups[i]
            groups[i] = gix > 0 ? remap[gix] : 0
        end
        # To catch potential bugs inducing unnecessary computations
        @assert oldngroups != ngroups
    end
    return ngroups, UInt[], Int[], sort
end


# Return a 3-tuple of a permutation that sorts rows into groups,
# and the positions of the first and last rows in each group in that permutation
# `groups` must contain group indices in 0:ngroups
# Rows with group index 0 are skipped (used when skipmissing=true)
# Partly uses the code of Wes McKinney's groupsort_indexer in pandas (file: src/groupby.pyx).
function compute_indices(groups::AbstractVector{<:Integer}, ngroups::Integer)
    # count elements in each group
    stops = zeros(Int, ngroups+1)
    @inbounds for gix in groups
        stops[gix+1] += 1
    end

    # group start positions in a sorted table
    starts = Vector{Int}(undef, ngroups+1)
    if length(starts) > 0
        starts[1] = 1
        @inbounds for i in 1:ngroups
            starts[i+1] = starts[i] + stops[i]
        end
    end

    # define row permutation that sorts them into groups
    rperm = Vector{Int}(undef, length(groups))
    copyto!(stops, starts)
    @inbounds for (i, gix) in enumerate(groups)
        rperm[stops[gix+1]] = i
        stops[gix+1] += 1
    end
    stops .-= 1

    # When skipmissing=true was used, group 0 corresponds to missings to drop
    # Otherwise it's empty
    popfirst!(starts)
    popfirst!(stops)

    return rperm, starts, stops
end

# Build RowGroupDict for a given DataFrame, using all of its columns as grouping keys
function group_rows(df::AbstractDataFrame)
    groups = Vector{Int}(undef, nrow(df))
    ngroups, rhashes, gslots, sorted =
        row_group_slots(ntuple(i -> df[!, i], ncol(df)), Val(true), groups, false, false)
    rperm, starts, stops = compute_indices(groups, ngroups)
    return RowGroupDict(df, rhashes, gslots, groups, rperm, starts, stops)
end

# Find index of a row in gd that matches given row by content, 0 if not found
function findrow(gd::RowGroupDict,
                 df::AbstractDataFrame,
                 gd_cols::Tuple{Vararg{AbstractVector}},
                 df_cols::Tuple{Vararg{AbstractVector}},
                 row::Int)
    (gd.df === df) && return row # same table, return itself
    # different tables, content matching required
    rhash = rowhash(df_cols, row)
    szm1 = length(gd.gslots)-1
    slotix = ini_slotix = rhash & szm1 + 1
    while true
        g_row = gd.gslots[slotix]
        if g_row == 0 || # not found
            (rhash == gd.rhashes[g_row] &&
            isequal_row(gd_cols, g_row, df_cols, row)) # found
            return g_row
        end
        slotix = (slotix & szm1) + 1 # miss, try the next slot
        (slotix == ini_slotix) && break
    end
    return 0 # not found
end

# Find indices of rows in 'gd' that match given row by content.
# return empty set if no row matches
function findrows(gd::RowGroupDict,
                  df::AbstractDataFrame,
                  gd_cols::Tuple{Vararg{AbstractVector}},
                  df_cols::Tuple{Vararg{AbstractVector}},
                  row::Int)
    g_row = findrow(gd, df, gd_cols, df_cols, row)
    (g_row == 0) && return view(gd.rperm, 0:-1)
    gix = gd.groups[g_row]
    return view(gd.rperm, gd.starts[gix]:gd.stops[gix])
end

function Base.getindex(gd::RowGroupDict, dfr::DataFrameRow)
    g_row = findrow(gd, parent(dfr), ntuple(i -> gd.df[!, i], ncol(gd.df)),
                    ntuple(i -> parent(dfr)[!, i], ncol(parent(dfr))), row(dfr))
    (g_row == 0) && throw(KeyError(dfr))
    gix = gd.groups[g_row]
    return view(gd.rperm, gd.starts[gix]:gd.stops[gix])
end
