/* ----------------------------------------------------------------------------
 * This file was automatically generated by SWIG (https://www.swig.org).
 * Version 4.2.1
 *
 * Do not make changes to this file unless you know what you are doing - modify
 * the SWIG interface file instead.
 * ----------------------------------------------------------------------------- */

// source: taglib.i

#ifndef SWIG_taglib_WRAP_H_
#define SWIG_taglib_WRAP_H_

class Swig_memory;

class SwigDirector_IOStream : public TagLib::IOStream
{
 public:
  SwigDirector_IOStream(int swig_p);
  virtual ~SwigDirector_IOStream();
  virtual TagLib::FileName name() const;
  virtual TagLib::ByteVector readBlock(size_t length);
  virtual void writeBlock(TagLib::ByteVector const &data);
  virtual void insert(TagLib::ByteVector const &data,TagLib::offset_t start,size_t replace);
  virtual void insert(TagLib::ByteVector const &data,TagLib::offset_t start);
  virtual void insert(TagLib::ByteVector const &data);
  virtual void removeBlock(TagLib::offset_t start,size_t length);
  virtual void removeBlock(TagLib::offset_t start);
  virtual void removeBlock();
  virtual bool readOnly() const;
  virtual bool isOpen() const;
  virtual void seek(TagLib::offset_t offset,TagLib::IOStream::Position p);
  virtual void seek(TagLib::offset_t offset);
  void _swig_upcall_clear() {
    TagLib::IOStream::clear();
  }
  virtual void clear();
  virtual TagLib::offset_t tell() const;
  virtual TagLib::offset_t length();
  virtual void truncate(TagLib::offset_t length);
 private:
  intgo go_val;
  Swig_memory *swig_mem;
};

#endif
