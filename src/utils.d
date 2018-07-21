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


// Forward elements from inputRange to outputRange until pred is true and update inputRange
long forwardUntil(alias pred, R1, R2)(ref R1 inputRange, R2 outputRange)
    if(isInputRange!R1 && isOutputRange!(R2, ElementType!R1))
{
    int count;

    for(count = 0 ; !inputRange.empty ; ++count)
    {
        auto first = inputRange.front;

        if(pred(first))
            break;

        outputRange.put(first);
        inputRange.popFront();
    }

    return count;
    //return refRange(&inputRange).tee(outputRange).countUntil!pred;
}

// Call func for each element of inputRange until pred is true and update inputRange
long forwardUntil(alias pred, alias func, R1)(ref R1 inputRange)
    if(isInputRange!R1)
{
    int count;

    for(count = 0 ; !inputRange.empty ; ++count)
    {
        auto first = inputRange.front;

        if(pred(first))
            break;

        func(first);
        inputRange.popFront();
    }

    return count;
    //return refRange(&inputRange).tee!func.countUntil!pred;
}

// Forward elements from inputRange to outputRange while pred is true and update inputRange
long forwardWhile(alias pred, R1, R2)(ref R1 inputRange, R2 outputRange)
    if(isInputRange!R1 && isOutputRange!(R2, ElementType!R1))
{
    int count;

    for(count = 0 ; !inputRange.empty ; ++count)
    {
        auto first = inputRange.front;

        if(!pred(first))
            break;

        outputRange.put(first);
        inputRange.popFront();
    }

    return count;
    //return refRange(&inputRange).tee(outputRange).countUntil!(a => !pred(a));
}

// Call func for each element of inputRange while pred is true and update inputRange
long forwardWhile(alias pred, alias func, R1)(ref R1 inputRange)
    if(isInputRange!R1)
{
    int count;

    for(count = 0 ; !inputRange.empty ; ++count)
    {
        auto first = inputRange.front;

        if(!pred(first))
            break;

        func(first);
        inputRange.popFront();
    }

    return count;
    //return refRange(&inputRange).tee!func.countUntil!(a => !pred(a));
}

// Forward one element if pred(inputRange.front) is true and update inputRange
bool forwardIf(alias pred, R1, R2)(ref R1 inputRange, R2 outputRange)
    if(isInputRange!R1 && isOutputRange!(R2, ElementType!R1))
{
    if(inputRange.empty)
        return false;

    auto first = inputRange.front;
    auto result = pred(first);

    if(result)
    {
        outputRange.put(first);
        inputRange.popFront();
    }

    return cast(bool)result;
}

// Call func if pred(inputRange.front) is true and update inputRange
bool forwardIf(alias pred, alias func, R1)(ref R1 inputRange)
    if(isInputRange!R1)
{
    if(inputRange.empty)
        return false;

    auto first = inputRange.front;
    bool result = pred(first);

    if(result)
    {
        func(first);
        inputRange.popFront();
    }

    return result;
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
