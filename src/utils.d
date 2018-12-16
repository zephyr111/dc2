/* Copyright (c) 2018 <Jérôme Richard>
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module utils;

import std.range;
import std.range.primitives;
import std.algorithm.comparison;
import std.algorithm.iteration;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.algorithm.mutation;
import std.string;
import std.ascii;
import std.utf;
import std.conv;
import std.traits;
import std.container;
import std.meta;
import std.functional;
import std.typecons;


// Forward elements from inputRange to outputRange until pred is true and update inputRange
long forwardUntil(alias pred, R1, R2)(ref R1 inputRange, R2 outputRange)
    if(isInputRange!R1 && isOutputRange!(R2, ElementType!R1)
        && ifTestable!(typeof(inputRange.front), unaryFun!pred))
{
    int count;

    for(count = 0 ; !inputRange.empty ; ++count)
    {
        auto first = inputRange.front;

        if(unaryFun!pred(first))
            break;

        outputRange.put(first);
        inputRange.popFront();
    }

    return count;
    //return refRange(&inputRange).tee(outputRange).countUntil!(unaryFun!pred);
}

// Call func for each element of inputRange until pred is true and update inputRange
long forwardUntil(alias pred, alias func, R1)(ref R1 inputRange)
    if(isInputRange!R1 && ifTestable!(typeof(inputRange.front), unaryFun!pred))
{
    int count;

    for(count = 0 ; !inputRange.empty ; ++count)
    {
        auto first = inputRange.front;

        if(unaryFun!pred(first))
            break;

        unaryFun!func(first);
        inputRange.popFront();
    }

    return count;
    //return refRange(&inputRange).tee!(unaryFun!func).countUntil!(unaryFun!pred);
}

// Forward elements from inputRange to outputRange while pred is true and update inputRange
long forwardWhile(alias pred, R1, R2)(ref R1 inputRange, R2 outputRange)
    if(isInputRange!R1 && isOutputRange!(R2, ElementType!R1)
        && ifTestable!(typeof(inputRange.front), unaryFun!pred))
{
    int count;

    for(count = 0 ; !inputRange.empty ; ++count)
    {
        auto first = inputRange.front;

        if(!unaryFun!pred(first))
            break;

        outputRange.put(first);
        inputRange.popFront();
    }

    return count;
    //return refRange(&inputRange).tee(outputRange).countUntil!(a => !(unaryFun!pred(a)));
}

// Call func for each element of inputRange while pred is true and update inputRange
long forwardWhile(alias pred, alias func, R1)(ref R1 inputRange)
    if(isInputRange!R1 && ifTestable!(typeof(inputRange.front), unaryFun!pred))
{
    int count;

    for(count = 0 ; !inputRange.empty ; ++count)
    {
        auto first = inputRange.front;

        if(!unaryFun!pred(first))
            break;

        unaryFun!func(first);
        inputRange.popFront();
    }

    return count;
    //return refRange(&inputRange).tee!(unaryFun!func).countUntil!(a => !(unaryFun!pred(a)));
}

// Forward one element if pred(inputRange.front) is true and update inputRange
bool forwardIf(alias pred, R1, R2)(ref R1 inputRange, R2 outputRange)
    if(isInputRange!R1 && isOutputRange!(R2, ElementType!R1)
        && ifTestable!(typeof(inputRange.front), unaryFun!pred))
{
    if(inputRange.empty)
        return false;

    auto first = inputRange.front;
    auto result = unaryFun!pred(first);

    if(result)
    {
        outputRange.put(first);
        inputRange.popFront();
    }

    return cast(bool)result;
}

// Call func if pred(inputRange.front) is true and update inputRange
bool forwardIf(alias pred, alias func, Range)(ref Range inputRange)
    if(isInputRange!Range && ifTestable!(typeof(inputRange.front), unaryFun!pred))
{
    if(inputRange.empty)
        return false;

    auto first = inputRange.front;
    bool result = unaryFun!pred(first);

    if(result)
    {
        unaryFun!func(first);
        inputRange.popFront();
    }

    return result;
}

// Skip the first element of inputRange if pred(element)
bool skipIf(alias pred, Range)(ref Range inputRange)
    if(isInputRange!Range && ifTestable!(typeof(inputRange.front), unaryFun!pred))
{
    if(inputRange.empty || !unaryFun!pred(inputRange.front))
        return false;

    inputRange.popFront();
    return true;
}

// Skip the first element of inputRange if pred(firstElement, e)
bool skipIf(alias pred = "a == b", Range, Element)(ref Range inputRange, Element e)
    if(is(typeof(binaryFun!pred(inputRange.front, e))) && isInputRange!Range)
{
    if(inputRange.empty || !binaryFun!pred(inputRange.front, e))
        return false;

    inputRange.popFront();
    return true;
}

// Return a range with all the replicated entries found in input
auto replicates(Range)(Range input)
    if(isInputRange!Range)
{
    struct Result
    {
        private
        {
            alias Element = typeof(_input.front);

            bool[Element] _lookup;
            Range _input;
        }


        this(Range input)
        {
            _input = input;
            findNext();
        }

        private void findNext()
        {
            while(!_input.empty)
            {
                auto val = _input.front;
                auto ptr = val in _lookup;

                if(ptr)
                    break;

                _lookup[val] = false;
                _input.popFront();
            }
        }

        @property bool empty()
        {
            return _input.empty;
        }

        @property auto front()
        {
            return _input.front;
        }

        void popFront()
        {
            _input.popFront();
            findNext();
        }

        @property auto save()
        {
            Result res;
            res._lookup = _lookup.dup;
            res._input = _input.save;
            return res;
        }
    }

    return Result(input);
}

// Look the longest prefix of inputRange that match with an element of elemsToFind
// Return the index in elemsToFind is returned or -1 if not found
// Complexity: O(longuestKey)
long startsWithAmong(alias elemsToFind, Range)(Range inputRange)
    if(isForwardRange!Range && isSomeChar!(ElementEncodingType!Range) && !isConvertibleToString!Range
        && isArray!(typeof(elemsToFind))) //&& isSomeString!(ElemType!(typeof(elemsToFind))))
{
    auto computeIndices(T)(T elems)
    {
        import std.algorithm.mutation : SwapStrategy;
        auto index = iota(elems.length).array;
        elems.makeIndex!((a, b) => a.walkLength>b.walkLength, SwapStrategy.stable)(index);
        return index;
    }
    enum elemIndices = computeIndices(elemsToFind);
    enum sortedElems = iota(elemsToFind.length).map!(id => elemsToFind[id]).array;
    enum withNullStr = sortedElems.any!empty;

    static if(withNullStr)
        return elemIndices[elemIndices.length-1];

    if(inputRange.empty)
        return -1;

    auto first = inputRange.front;

    static foreach(eId ; elemIndices)
    {{
        enum eVal = elemsToFind[eId];
        enum eFront = eVal.front;

        static if(eVal.length == 1)
        {
            if(first == eFront)
                return eId;
        }
        else
        {
            if(first == eFront && inputRange.startsWith(eVal))
                return eId;
        }
    }}

    return -1;
}

enum EscapeType
{
    ALL,
    ONLY_SQUOTES, // only simple-quoted strings, eg. 'char'
    ONLY_DQUOTES, // only double-quoted strings, eg. "string"
    ONLY_BQUOTES, // only back-quoted strings, eg. `printed expressions`
    REPR_SQUOTES, // same as ONLY_SQUOTES + ONLY_BQUOTES
    REPR_DQUOTES, // same as ONLY_DQUOTES + ONLY_BQUOTES
    REPR_BQUOTES, // same as ONLY_BQUOTES + ONLY_BQUOTES
}

// Return a pretty printable range/string of a given character
auto escapeChar(EscapeType esc = EscapeType.ALL)(dchar c)
{
    static immutable ctrlChars = [
          "\\0", "\\x01", "\\x02", "\\x03", "\\x04", "\\x05", "\\x06",   "\\a",
          "\\b",   "\\t",   "\\n",   "\\v",   "\\f",   "\\r", "\\x0E", "\\x0F",
        "\\x10", "\\x11", "\\x12", "\\x13", "\\x14", "\\x15", "\\x16", "\\x17",
        "\\x18", "\\x19", "\\x1A",   "\\e", "\\x1C", "\\x1D", "\\x1E", "\\x1F",
    ];

    static immutable stdChars = " !\"#$%&\'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";

    with(EscapeType)
    {
        if(c < 0x20)
            return ctrlChars[c];
        else if(c == '\\')
            return "\\\\";
        else if(c == '\'' && esc.among(ALL, ONLY_SQUOTES, REPR_SQUOTES))
            return "\\'";
        else if(c == '"' && esc.among(ALL, ONLY_DQUOTES, REPR_DQUOTES))
            return "\\\"";
        else if(c == '`' && esc.among(ALL, ONLY_BQUOTES, REPR_BQUOTES))
            return "\\`";
        else if(c == 0x7F)
            return "\\x7F";
        else if(c.isASCII)
            return stdChars[c-32..c-32+1];
        else
            return "\\u" ~ to!string(cast(int)c, 16).rightJustify(8, '0');
    }
}

// Escape special characters (control chars, tabs, new lines, etc.)
// isSomeString!Range ?
auto escape(EscapeType esc = EscapeType.ALL, Range)(Range inputRange)
    if(isInputRange!Range && isSomeChar!(ElementEncodingType!Range) && !isConvertibleToString!Range)
{
    return inputRange.byChar.map!(escapeChar!esc).join;
}

// InputRange/OutputRange that behave like a stack
// Usefull for macro substitution
struct Stack(T)
{
    private
    {
        alias This = typeof(this);

        T[] _data = [];
    }


    @property bool empty() const pure
    {
        return _data.empty;
    }

    @property auto front()
    {
        assert(!empty);
        return _data[$-1];
    }

    void popFront()
    {
        assert(!empty);
        _data.length = _data.length-1;
    }

    void put(T e)
    {
        if(_data.capacity == _data.length)
            _data.reserve(max(_data.length, 4)*2);

        _data ~= e;
    }

    // Insert many elements one by one
    void putMany(Range)(Range input)
        if(isInputRange!Range && is(ElementType!Range : T) && hasLength!Range)
    {
        if(_data.capacity < _data.length+input.length)
        {
            auto capacity = max(_data.capacity, 4);
            while(capacity < _data.length+input.length)
                capacity *= 2;
            _data.reserve(capacity);
        }

        auto i = _data.length;
        _data.length += input.length;
        foreach(e ; input)
            _data[i++] = e;
    }

    // Insert many elements one by one
    void putMany(Range)(Range input)
        if(isInputRange!Range && is(ElementType!Range : T) && !hasLength!Range)
    {
        foreach(e ; input)
            put(e);
    }

    // Insert many elements one by one
    void putMany(const T[] arr)
    {
        if(_data.capacity < _data.length+arr.length)
        {
            auto capacity = max(_data.capacity, 4);
            while(capacity < _data.length+arr.length)
                capacity *= 2;
            _data.reserve(capacity);
        }

        _data ~= arr;
    }

    // Insert a chunk of elements so they can be 
    // retrived later in the same order
    void putChunk(Range)(Range input)
        if(isInputRange!Range && is(ElementType!Range : T))
    {
        putMany(input.retro);
    }

    // Insert a chunk of elements so they can be 
    // retrived later in the same order
    void putChunk(const T[] arr)
    {
        putMany(arr.retro);
    }
 
    @property auto length() const pure
    {
        return _data.length;
    }

    @property auto save()
    {
        auto res = This();
        res._data = _data.dup;
        return res;
    }
};

// InputRange/OutputRange that behave like a bufferized stack
// Usefull for macro substitution or file inclusion
// Added ranges are owned by the structure (hence, they must not be used or deleted)
struct BufferedStack(Range, RangeState = void)
    if(isInputRange!Range)
{
    private
    {
        static if(is(RangeState : void))
            SList!Range _data;
        else
            SList!(Tuple!(Range, RangeState)) _data;
    }


    @property bool empty()
    {
        assert(_data.empty || !_data.front.empty);
        return _data.empty;
    }

    @property auto front()
    {
        assert(!_data.empty && !_data.front.empty);
        static if(is(RangeState : void))
            return _data.front.front;
        else
            return _data.front[0].front;
    }

    static if(!is(RangeState : void))
    {
        @property auto state()
        {
            assert(!_data.empty);
            return _data.front[1];
        }
    }

    void popFront()
    {
        assert(!empty);
        static if(is(RangeState : void))
        {
            _data.front.popFront();

            if(_data.front.empty)
                _data.stableRemoveFront();
        }
        else
        {
            _data.front[0].popFront();

            if(_data.front[0].empty)
                _data.stableRemoveFront();
        }
    }

    @property auto buffers()
    {
        return _data[];
    }

    static if(is(RangeState : void))
    {
        void put(Range e)
        {
            if(!e.empty)
                _data.stableInsertFront(e);
        }
    }
    else
    {
        void put(Tuple!(Range, RangeState) e)
        {
            if(!e[0].empty)
                _data.stableInsertFront(e);
        }
    }

    static if(isForwardRange!Range)
    {
        @property auto save()
        {
            typeof(this) result;
            static if(is(RangeState : void))
                result._data = SList!Range(_data[].map!(a => a.save));
            else
                result._data = SList!(Tuple!(Range, RangeState))(_data[].map!(a => tuple(a[0].save, a[1].dup)));
            return result;
        }
    }
};

// A fast growable circular queue
struct CircularQueue(T)
{
    private
    {
        alias This = typeof(this);

        size_t _length;
        size_t _first;
        size_t _last;
        T[] _data = [T.init];
    }

 
    this(T[] items...)
    {
        foreach(x; items)
            put(x);
    }

    @property auto dup() const
    {
        auto result = This();
        result._length = _length;
        result._first = _first;
        result._last = _last;
        result._data = _data.dup;
        return result;
    }
 
    @property bool empty() const pure
    {
        return _length == 0;
    }
 
    @property T front()
    {
        assert(_length != 0);
        return _data[_first];
    }
 
    @property auto length() const pure
    {
        return _length;
    }
 
    T opIndex(in size_t i)
    {
        assert(i < _length);
        return _data[(_first + i) & (_data.length - 1)];
    }
 
    void put(T item)
    {
        if(_length >= _data.length)
        {
            immutable oldALen = _data.length;
            _data.length *= 2;

            if(_last < _first)
            {
                _data[oldALen .. oldALen+_last+1] = _data[0 .. _last+1];
                static if(hasIndirections!T)
                    _data[0 .. _last+1] = T.init; // Help for the GC.
                _last += oldALen;
            }
        }

        _last = (_last + 1) & (_data.length - 1);
        _data[_last] = item;
        _length++;
    }

    void popFront()
    {
        assert(_length != 0);
        static if(hasIndirections!T)
            _data[_first] = T.init; // Help for the GC.
        _first = (_first + 1) & (_data.length - 1);
        _length--;
    }
}

// See lookAhead function
struct LookAhead(Range)
{
    private
    {
        alias This = typeof(this);
        alias Element = ElementType!Range;

        final class Local
        {
            CircularQueue!Element data;
            int count = 0;
        }

        final class Shared
        {
            Range input;
            Local[] locals;

            this(Range input, Local[] locals)
            {
                this.input = input;
                this.locals = locals;
            }
        }

        Shared _shared;
        Local _local;
    }


    this(Range input)
    {
        _local = new Local();
        _shared = new Shared(input, [_local]);
    }

    private this(Shared sharedPtr, Local local)
    {
        assert(sharedPtr !is null);
        assert(local !is null);
        _local = new Local();
        _local.data = local.data.dup;
        _shared = sharedPtr;
        _shared.locals ~= _local;
    }

    // Used to move the structure (destructive-copy)
    this(this)
    {
        assert((_local is null) == (_shared is null));
        assert(_local is null || _local.count >= 0);

        // Instances not yet truly built (created via struct.init)
        if(_local is null)
            return;

        _local.count++;
    }

    // Used to copy the structure
    //@disable 
    void opAssign()(auto ref This rhs)
    {
        assert((_local is null) == (_shared is null));
        assert(_local is null || _local.count >= 0);
        assert((rhs._local is null) == (rhs._shared is null));
        assert(rhs._local is null || rhs._local.count >= 0);

        auto oldLocal = _local;
        auto oldShared = _shared;

        _local = rhs._local;
        _shared = rhs._shared;

        // rhs not created via struct.init
        if(_local !is null)
            _local.count++;

        // lhs not created via struct.init
        if(oldLocal !is null && oldLocal.count-- == 0)
            oldShared.locals = oldShared.locals.remove!(a => a is oldLocal);
    }

    ~this()
    {
        assert((_local is null) == (_shared is null));
        assert(_local is null || _local.count >= 0);

        // Instance created via struct.init
        if(_local is null)
            return;

        if(_local.count-- == 0)
            _shared.locals = _shared.locals.remove!(a => a is _local);
    }

    @property bool empty()
    {
        assert(_local !is null && _shared !is null);
        return _shared.input.empty && _local.data.empty;
    }

    @property auto front()
    {
        assert(_local !is null && _shared !is null);
        assert(!empty);

        if(!_local.data.empty)
            return _local.data.front;

        return _shared.input.front;
    }

    void popFront()
    {
        assert(_local !is null && _shared !is null);
        assert(!empty);

        if(!_local.data.empty)
            return _local.data.popFront();

        auto elem = _shared.input.front;

        foreach(e ; _shared.locals)
            if(e !is _local)
                e.data.put(elem);

        _shared.input.popFront();
    }

    @property auto save()
    {
        return This(_shared, _local);
    }
}

// A good candidate for a faster look-ahead parsing, that rely on 
// saving/restoring states manually preventing GC-related overheads
// This break the forward range API and so the possibility to 
// call many phobos functions...
/*struct FastLookAhead(Range)
{
    private
    {
        alias This = typeof(this);
        alias Element = typeof(Range.front);

        Range _input;
        CircularQueue!Element _data;
        bool _register = false;
    }


    this(Range input)
    {
        _input = input;
    }

    @property bool empty()
    {
        return _input.empty && _data.empty;
    }

    @property auto front()
    {
        if(!_data.empty)
            return _data.front;
        return _input.front;
    }

    void popFront()
    {
        if(_register)
            _data.put(_input.front);
        else if(!_data.empty)
            return _data.popFront();
        _input.popFront();
    }

    @property void saveState()
    {
        assert(!_register && _data.empty);
        _register = true;
    }

    @property void dropState()
    {
        assert(_register);
        _register = false;
        _data.walkLength;
    }

    @property void restoreState()
    {
        assert(_register);
        _register = false;
    }
}*/

// Transform an input range to a forward range by temporary 
// saving elements into a shared local data structure
// This enable look-ahead parsing (but may introduce a significant overhead)
// The amount of simultaneous saved ranges should be small to minimize overheads
auto lookAhead(Range)(Range input)
    if(isInputRange!Range)
{
    return LookAhead!Range(input);
}

alias LookAheadRange(Range) = LookAhead!Range;

// Convert value of type SrcEnum to a DstEnum assuming that the contiguous 
// range [start;end] of enum value in SrcEnum match with those of DstEnum
DstEnum convertEnum(SrcEnum, DstEnum, string start, string end)(SrcEnum value)
    if(isType!SrcEnum && !isAggregateType!SrcEnum
        && isType!DstEnum && !isAggregateType!DstEnum)
{
    static assert(isIntegral!(OriginalType!SrcEnum));
    static assert(isIntegral!(OriginalType!DstEnum));
    static assert(is(OriginalType!SrcEnum == OriginalType!DstEnum));
    enum lexerStart = mixin("SrcEnum." ~ start ~ ".asOriginalType");
    enum parserStart = mixin("DstEnum." ~ start ~ ".asOriginalType");
    enum lexerEnd = mixin("SrcEnum." ~ end ~ ".asOriginalType");
    enum parserEnd = mixin("DstEnum." ~ end ~ ".asOriginalType");
    static assert(lexerEnd-lexerStart == parserEnd-parserStart);
    return cast(DstEnum)(parserStart + (value.asOriginalType - lexerStart));
}

