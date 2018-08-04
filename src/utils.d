import std.range;
import std.range.primitives;
import std.algorithm.iteration;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.string;
import std.ascii;
import std.utf;
import std.conv;
import std.traits;
import std.container;
import std.meta;
import std.functional;


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

pragma(msg, "[OPTION] enable sliping by element rather than using only a predicate");
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

auto replicates(Range)(Range input)
    if(isInputRange!Range)
{
    struct Result
    {
        alias Element = typeof(_input.front);

        private bool[Element] _lookup;
        private Range _input;

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
        import std.algorithm.sorting : SwapStrategy;
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

auto escapeChar(dchar c)
{
    static immutable ctrlChars = [
          "\\0", "\\x01", "\\x02", "\\x03", "\\x04", "\\x05", "\\x06",   "\\a",
          "\\b",   "\\t",   "\\n",   "\\v",   "\\f",   "\\r", "\\x0E", "\\x0F",
        "\\x10", "\\x11", "\\x12", "\\x13", "\\x14", "\\x15", "\\x16", "\\x17",
        "\\x18", "\\x19", "\\x1A",   "\\e", "\\x1C", "\\x1D", "\\x1E", "\\x1F",
    ];

    static immutable stdChars = " !\"#$%&\'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";

    if(c < 0x20) return ctrlChars[c];
    else if(c == '\'') return "\\'";
    else if(c == '"') return "\\\"";
    else if(c == '`') return "\\`";
    else if(c == 0x7F) return "\\x7F";
    else if(c.isASCII) return stdChars[c-32..c-32+1];
    else return "\\u" ~ to!string(cast(int)c, 16).rightJustify(8, '0');
}

// Escape special characters (control chars, tabs, new lines, etc.)
// isSomeString!Range ?
auto escape(Range)(Range inputRange)
    if(isInputRange!Range && isSomeChar!(ElementEncodingType!Range) && !isConvertibleToString!Range)
{
    return inputRange.map!escapeChar.join;
}

// InputRange/OutputRange that behave like a bufferized stack
// Usefull for macro substitution or file inclusion
// Added ranges are owned by the structure (hence, they must not be used or deleted)
struct BufferedStack(Range)
    if(isInputRange!Range)
{
    SList!Range _data;

    @property bool empty()
    {
        return _data.empty;
    }

    @property auto front()
    {
        return _data.front.front;
    }

    void popFront()
    {
        _data.front.popFront();

        if(_data.front.empty)
            _data.stableRemoveFront();
    }

    @property auto buffers()
    {
        return _data[];
    }

    void put(Range e)
    {
        if(!e.empty)
            _data.stableInsertFront(e);
    }

    static if(isForwardRange!Range)
    {
        @property auto save()
        {
            BufferedStack!Range result;
            result._data = SList!Range(_data[].map!(a => a.save));
            return result;
        }
    }
};

alias MergeRange(Ranges...) = ReturnType!(chain!(staticMap!(RefRange, Ranges)));

// Merge multiples sub-ranges into a bigger unique merged range
// Sub-ranges MUST exists as long as the resulting range is used
void mergeRange(Ranges...)(out MergeRange!(Ranges) merged, ref Ranges subRanges)
{
    // Enable copying refRange internal pointers (rather than a per-value copy)
    staticMap!(RefRange, Ranges) nullRefRanges;
    static foreach(i, range; subRanges)
        nullRefRanges[i] = refRange!(typeof(range))(null);
    merged = chain(nullRefRanges);

    // Actual internal pointer copy
    staticMap!(RefRange, Ranges) refRanges;
    static foreach(i, _; subRanges)
        refRanges[i] = refRange(&subRanges[i]);
    merged = chain(refRanges);
}

