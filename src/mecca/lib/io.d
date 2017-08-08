/// File descriptor management
module mecca.lib.io;

import core.sys.posix.unistd;

import mecca.lib.exception;

/**
 * File descriptor wrapper
 *
 * This wrapper's main purpose is to protect the fd against leakage. It does not actually $(I do) anything.
 */
struct FD {
private:
    enum InvalidFd = -1;
    int fd = InvalidFd;

public:
    @disable this(this);

    /**
     * Initialize from an OS file descriptor.
     *
     * Parameters:
     *  fd = OS handle of file to wrap.
     */
    this(int fd) nothrow @safe @nogc {
        ASSERT!"FD initialized with an invalid FD %s"(fd>=0, fd);
        this.fd = fd;
    }

    ~this() nothrow @safe @nogc {
        close();
    }

    /**
     * Close the OS handle prematurely.
     *
     * Closes the OS handle. This happens automatically on struct destruction. It is only necessary to call this method if you wish to close
     * the underlying FD before the struct goes out of scope.
     */
    void close() nothrow @safe @nogc {
        if( fd != InvalidFd ) {
            .close(fd);
        }

        fd = InvalidFd;
    }

    /**
      * Obtain the underlying OS handle
      *
      * This returns the underlying OS handle for use directly with OS calls.
      *
      * Warning:
      * Do not use this function to directly call the close system call. Doing so may lead to quite difficult to debug problems across your
      * program. If another part of the program gets the same FD number, it can be quite difficult to find out what went wrong.
      */
    @property int fileNo() pure nothrow @safe @nogc {
        return fd;
    }
}

unittest {
    import core.stdc.errno;
    import core.sys.posix.fcntl;
    import std.conv;

    int fd1copy, fd2copy;

    {
        auto fd = FD(open("/tmp/meccaUTfile1", O_CREAT|O_RDWR|O_TRUNC, octal!666));
        fd1copy = fd.fileNo;

        unlink("/tmp/meccaUTfile1");

        fd = FD(open("/tmp/meccaUTfile2", O_CREAT|O_RDWR|O_TRUNC, octal!666));
        fd2copy = fd.fileNo;

        unlink("/tmp/meccaUTfile2");
    }

    assert( close(fd1copy)<0 && errno==EBADF, "FD1 was not closed" );
    assert( close(fd2copy)<0 && errno==EBADF, "FD2 was not closed" );
}