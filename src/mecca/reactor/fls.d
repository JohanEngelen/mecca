/// Fiber local storage
module mecca.reactor.fls;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import std.traits;

import mecca.log;
import mecca.lib.exception;
import mecca.reactor;

enum FLS_AREA_SIZE = 512;

struct FLSArea {
    align( (void*).alignof ):
    __gshared static const FLSArea flsAreaInit;
    __gshared static int _flsOffset = 0;
    /* thread local */ static FLSArea* thisFls;

    ubyte[FLS_AREA_SIZE] data;

    void reset() nothrow @safe @nogc {
        pragma(inline, true);
        data[] = flsAreaInit.data[];
    }

    @notrace void switchTo() nothrow @trusted @nogc {
        pragma(inline, true);
        thisFls = &this;
    }

    static void switchToNone() nothrow @safe @nogc {
        pragma(inline, true);
        thisFls = null;
    }

    private static int alloc(T)(T initVal) {
        // Make sure allocation is properly aligned
        import std.string : format;
        static assert(T.alignof <= (void*).alignof, "Cannot allocate on FLS type %s with alignement %s > ptr alignement"
                .format(T.stringof, T.alignof));
        _flsOffset += T.alignof - 1;
        _flsOffset -= _flsOffset % T.alignof;

        int offset = _flsOffset;
        _flsOffset += T.sizeof;
        assert (_flsOffset <= data.sizeof);
        *cast(T*)(flsAreaInit.data.ptr + offset) = initVal;
        return offset;
    }
}
static assert(FLSArea.alignof == (void*).alignof, "FLSArea must have same alignement as a pointer");
static assert((FLSArea.data.offsetof % (void*).alignof) == 0, "FLSArea data must have same alignement as a pointer");

/**
 Construct for defining new fiber local storage variables.

 The file, mod and line template params should be ignored. They are used merely to ensure that each FiberLocal
 definition is unique.

 To use, alias a name to FiberLocal like so:

---
alias someName = FiberLocal!(uint, 12);
---

 Any reference to `someName` will reference a fiber local variable of type `uint` with an init value of 12.

Note:
 It is important to understand that `someName` actually aliases a `@property` function that returns a reference to said
 variable. Under most circumstances this makes no difference. If you wish to take the variable's address, however, you
 need to explicitly invoke the function, or you'll get a pointer to the function rather than the variable:

---
auto ptr1 = &someName;
pragma(msg, typeof(ptr1)); // ref uint function() nothrow @nogc @property @trusted
auto ptr2 = &someName();
pragma(msg, typeof(ptr2)); // uint*
---

Params:
T = The type of the FLS variable
initVal = The variable initial value
*/
template FiberLocal(T, T initVal=T.init, string file = __FILE__, string mod = __MODULE__, ulong line = __LINE__) {
    __gshared int offset = -1;

    shared static this() {
        static int var;
        if( offset!=-1 ) {
            META!"#DMDBUG issue 18868: static this ran twice for FiberLocal!(%s) defined at %s:%s"(T.stringof, file, line);
        } else {
            offset = FLSArea.alloc!T(initVal);
        }
    }

    @property ref T FiberLocal() @trusted {
        assert (FLSArea.thisFls !is null && offset >= 0);
        return *cast(T*)(FLSArea.thisFls.data.ptr + offset);
    }
}

// XXX Deprecation candidate, intentionally left undocumented
// Returns a $(B reference) to another fiber's FLS variable.
template getFiberFlsLvalue(alias FLS) {
    alias T = ReturnType!FLS;

    T* getFiberFlsLvalue(FiberHandle fib) nothrow @nogc {
        ReactorFiber* reactorFiber = fib.get();
        if( reactorFiber is null )
            return null;

        size_t offset = cast(void*)(&FLS()) - cast(void*)theReactor.thisFiber.params.flsBlock.data.ptr;
        DBG_ASSERT!"setFiberFls offset %s out of bounds %s"(offset<FLS_AREA_SIZE, offset, FLS_AREA_SIZE);
        return cast(T*)(reactorFiber.params.flsBlock.data.ptr + offset);
    }
}

/// Set the FLS variable of another fiber
template setFiberFls(alias FLS) {
    alias T = ReturnType!FLS;

    void setFiberFls(FiberHandle fib, T value) nothrow @nogc {
        T* fls = getFiberFlsLvalue!FLS(fib);

        if( fls !is null ) {
            *fls = value;
        }
    }
}

version (unittest) {
    alias myFls = FiberLocal!(int, 200);
    alias yourFls = FiberLocal!(double, 0.9);
}

unittest {
    FLSArea area1;
    FLSArea area2;

    area1.reset();
    area2.reset();

    scope(exit) FLSArea.thisFls = null;

    area1.switchTo();
    assert (myFls == 200);
    assert (yourFls == 0.9);

    myFls = 19;
    yourFls = 3.14;

    area2.switchTo();
    assert (myFls == 200);
    assert (yourFls == 0.9);

    myFls = 38;
    yourFls = 6.28;

    assert (myFls == 38);

    area1.switchTo();
    assert (myFls == 19);
    assert (yourFls == 3.14);

    area2.switchTo();
    assert (yourFls == 6.28);
}


unittest {
    align(64) struct A {
        align(64):
        uint a;
    }
    static assert( !__traits(compiles, FiberLocal!(A, "wontWork", A( 12 ))) );
}

unittest {
    import mecca.reactor.sync.event : Event;

    Event sync;

    void fiberBody() {
        assert(myFls == 200);
        sync.wait();
        assert(myFls == 23);
    }

    testWithReactor({
        auto fiber = theReactor.spawnFiber(&fiberBody);
        theReactor.yield();
        setFiberFls!myFls(fiber, 23);
        sync.set();
        theReactor.yield();
        theReactor.yield();
        assert(myFls == 200);
    });
}

/+
unittest {
    alias someName = FiberLocal!(uint, 12);

    auto ptr1 = &someName;
    pragma(msg, typeof(ptr1));
    auto ptr2 = &someName();
    pragma(msg, typeof(ptr2));
}
+/
