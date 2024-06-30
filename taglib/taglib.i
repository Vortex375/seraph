%module(directors="1") taglib

%{
// #cgo CXXFLAGS: -fpermissive
#include <taglib/taglib_export.h>
#include <taglib/taglib.h>
#include <taglib/tvariant.h>
#include <taglib/tbytevector.h>
#include <taglib/tstring.h>
#include <taglib/tlist.h>
#include <taglib/tstringlist.h>
#include <taglib/tmap.h>
#include <taglib/tpropertymap.h>
#include <taglib/audioproperties.h>
#include <taglib/tiostream.h>
#include <taglib/tfile.h>
#include <taglib/tag.h>
#include <taglib/fileref.h>
%}

%include <taglib/taglib_export.h>
%include <taglib/taglib.h>

// Forward declaration needed for friend function
namespace TagLib { class Variant; }

/*!
 * \relates TagLib::Variant
 *
 * Send the variant to an output stream.
 */
TAGLIB_EXPORT std::ostream &operator<<(std::ostream &s, const TagLib::Variant &v);

namespace TagLib {

  class String;
  class StringList;
  class ByteVector;
  class ByteVectorList;

  //! An implicitly shared discriminated union.

  /*!
   * This is an implicitly shared discriminated union.
   *
   * The use of implicit sharing means that copying a variant is cheap.
   * These Variant objects are immutable (have only const methods).
   */
  class TAGLIB_EXPORT Variant
  {
  public:
    /*!
     * Types which can be stored in a variant.
     */
    // The number and order of these types must correspond to the template
    // parameters for StdVariantType in tvariant.cpp!
    enum Type {
      Void,           //!< variant is empty
      Bool,           //!< \c bool
      Int,            //!< \c int
      UInt,           //!< <tt>unsigned int</tt>
      LongLong,       //!< <tt>long long</tt>
      ULongLong,      //!< <tt>unsigned long long</tt>
      Double,         //!< \c double
      String,         //!< String
      StringList,     //!< StringList
      ByteVector,     //!< ByteVector
      ByteVectorList, //!< ByteVectorList
      VariantList,    //!< \link TagLib::VariantList VariantList \endlink
      VariantMap      //!< \link TagLib::VariantMap VariantMap \endlink
    };

    /*!
     * Constructs an empty Variant.
     */
    Variant();

    Variant(int val);
    Variant(unsigned int val);
    Variant(long long val);
    Variant(unsigned long long val);
    Variant(bool val);
    Variant(double val);
    Variant(const char *val);
    Variant(const TagLib::String &val);
    Variant(const TagLib::StringList &val);
    Variant(const TagLib::ByteVector &val);
    Variant(const TagLib::ByteVectorList &val);
    Variant(const TagLib::List<TagLib::Variant> &val);
    Variant(const TagLib::Map<TagLib::String, TagLib::Variant> &val);

    /*!
     * Make a shallow, implicitly shared, copy of \a v.  Because this is
     * implicitly shared, this method is lightweight and suitable for
     * pass-by-value usage.
     */
    Variant(const Variant &v);

    /*!
     * Destroys this Variant instance.
     */
    ~Variant();

    /*!
     * Get the type which is currently stored in this Variant.
     */
    Type type() const;

    /*!
     * Returns \c true if the Variant is empty.
     */
    bool isEmpty() const;

    /*!
     * Extracts a value from the Variant.
     * If \a ok is passed, its boolean variable will be set to \c true if the
     * Variant contains the correct type, and the returned value is the value
     * of the Variant.  Otherwise, the \a ok variable is set to \c false and
     * a dummy default value is returned.
     */
    int toInt(bool *ok = nullptr) const;

    //! \copydoc toInt()
    unsigned int toUInt(bool *ok = nullptr) const;
    //! \copydoc toInt()
    long long toLongLong(bool *ok = nullptr) const;
    //! \copydoc toInt()
    unsigned long long toULongLong(bool *ok = nullptr) const;
    //! \copydoc toInt()
    bool toBool(bool *ok = nullptr) const;
    //! \copydoc toInt()
    double toDouble(bool *ok = nullptr) const;
    //! \copydoc toInt()
    TagLib::String toString(bool *ok = nullptr) const;
    //! \copydoc toInt()
    TagLib::StringList toStringList(bool *ok = nullptr) const;
    //! \copydoc toInt()
    TagLib::ByteVector toByteVector(bool *ok = nullptr) const;
    //! \copydoc toInt()
    TagLib::ByteVectorList toByteVectorList(bool *ok = nullptr) const;
    //! \copydoc toInt()
    TagLib::List<TagLib::Variant> toList(bool *ok = nullptr) const;
    //! \copydoc toInt()
    TagLib::Map<TagLib::String, TagLib::Variant> toMap(bool *ok = nullptr) const;

    /*!
     * Extracts value of type \a T from the Variant.
     * If \a ok is passed, its boolean variable will be set to \c true if the
     * Variant contains the correct type, and the returned value is the value
     * of the Variant.  Otherwise, the \a ok variable is set to \c false and
     * a dummy default value is returned.
     */
    template<typename T>
    T value(bool *ok = nullptr) const;

    /*!
     * Returns \c true if the Variant and \a v are of the same type and contain the
     * same value.
     */
    bool operator==(const Variant &v) const;

    /*!
     * Returns \c true if the Variant and \a v  differ in type or value.
     */
    bool operator!=(const Variant &v) const;

    /*!
     * Performs a shallow, implicitly shared, copy of \a v, overwriting the
     * Variant's current data.
     */
    Variant &operator=(const Variant &v);

  private:
    friend TAGLIB_EXPORT std::ostream& ::operator<<(std::ostream &s, const TagLib::Variant &v);
    class VariantPrivate;
    TAGLIB_MSVC_SUPPRESS_WARNING_NEEDS_TO_HAVE_DLL_INTERFACE
    std::shared_ptr<VariantPrivate> d;
  };

  /*! A list of Variant elements. */
  using VariantList = TagLib::List<TagLib::Variant>;

  /*! A map with String keys and Variant values. */
  using VariantMap = TagLib::Map<TagLib::String, TagLib::Variant>;

  // extern template TAGLIB_EXPORT bool Variant::value(bool *ok) const;
  // extern template TAGLIB_EXPORT int Variant::value(bool *ok) const;
  // extern template TAGLIB_EXPORT unsigned int Variant::value(bool *ok) const;
  // extern template TAGLIB_EXPORT long long Variant::value(bool *ok) const;
  // extern template TAGLIB_EXPORT unsigned long long Variant::value(bool *ok) const;
  // extern template TAGLIB_EXPORT double Variant::value(bool *ok) const;
  // extern template TAGLIB_EXPORT String Variant::value(bool *ok) const;
  // extern template TAGLIB_EXPORT StringList Variant::value(bool *ok) const;
  // extern template TAGLIB_EXPORT ByteVector Variant::value(bool *ok) const;
  // extern template TAGLIB_EXPORT ByteVectorList Variant::value(bool *ok) const;
  // extern template TAGLIB_EXPORT VariantList Variant::value(bool *ok) const;
  // extern template TAGLIB_EXPORT VariantMap Variant::value(bool *ok) const;
}  // namespace TagLib

%include <taglib/tstring.h>
%include <taglib/tbytevector.h>
%include <taglib/audioproperties.h>
%include <taglib/tlist.h>
%include <taglib/tmap.h>
%include <taglib/tpropertymap.h>
%include <taglib/tstringlist.h>

%feature("director") IOStream;
%include <taglib/tiostream.h>
%include <taglib/tfile.h>
%include <taglib/tag.h>
%include <taglib/fileref.h>