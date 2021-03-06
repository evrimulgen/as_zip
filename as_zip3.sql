﻿CREATE OR REPLACE package as_zip3
is
--
  function file2blob
    ( p_dir varchar2
    , p_file_name varchar2
    )
  return blob;
--
  procedure add1file
    ( p_zipped_blob in out blob
    , p_name varchar2
    , p_content blob
    , p_password varchar2 := null
    );
--
  procedure finish_zip( p_zipped_blob in out blob );
--
  procedure save_zip
    ( p_zipped_blob blob
    , p_dir varchar2 := 'MY_DIR'
    , p_filename varchar2 := 'my.zip'
    );
--
end;
/
CREATE OR REPLACE package body as_zip3
is
--
  c_LOCAL_FILE_HEADER        constant raw(4) := hextoraw( '504B0304' ); -- Local file header signature
  c_END_OF_CENTRAL_DIRECTORY constant raw(4) := hextoraw( '504B0506' ); -- End of central directory signature
--
  function little_endian( p_big number, p_bytes pls_integer := 4 )
  return raw
  is
  begin
    return utl_raw.substr( utl_raw.cast_from_binary_integer( p_big, utl_raw.little_endian ), 1, p_bytes );
  end;
--
  function blob2num( p_blob blob, p_len integer, p_pos integer )
  return number
  is
  begin
    return utl_raw.cast_to_binary_integer( dbms_lob.substr( p_blob, p_len, p_pos ), utl_raw.little_endian );
  end;
--
  function file2blob
    ( p_dir varchar2
    , p_file_name varchar2
    )
  return blob
  is
    file_lob bfile;
    file_blob blob;
  begin
    file_lob := bfilename( p_dir, p_file_name );
    dbms_lob.open( file_lob, dbms_lob.file_readonly );
    dbms_lob.createtemporary( file_blob, true );
    dbms_lob.loadfromfile( file_blob, file_lob, dbms_lob.lobmaxsize );
    dbms_lob.close( file_lob );
    return file_blob;
  exception
    when others then
      if dbms_lob.isopen( file_lob ) = 1
      then
        dbms_lob.close( file_lob );
      end if;
      if dbms_lob.istemporary( file_blob ) = 1
      then
        dbms_lob.freetemporary( file_blob );
      end if;
      raise;
  end;
--
  function encrypt( p_pw varchar2, p_src blob )
  return blob
  is
    t_salt raw(16);
    t_key  raw(32);
    t_pw raw(32767) := utl_raw.cast_to_raw( p_pw );
    t_key_bits pls_integer := 256;
    t_key_length pls_integer := t_key_bits / 8 * 2 + 2;
    t_cnt pls_integer := 1000;
    t_keys raw(32767); 
    t_sum raw(32767); 
    t_mac raw(20);
    t_iv raw(16);
    t_block raw(16);
    t_len pls_integer;
    t_rv blob; 
    t_tmp blob; 
  begin
    t_salt := dbms_crypto.randombytes( t_key_bits / 16 );
    for i in 1 .. ceil( t_key_length / 20 )
    loop
      t_mac := dbms_crypto.mac( utl_raw.concat( t_salt, to_char( i, 'fm0xxxxxxx' ) ), dbms_crypto.HMAC_SH1, t_pw );
      t_sum := t_mac;
      for j in 1 .. t_cnt - 1
      loop  
        t_mac := dbms_crypto.mac( t_mac, dbms_crypto.HMAC_SH1, t_pw );
        t_sum := utl_raw.bit_xor( t_mac, t_sum );
      end loop;
      t_keys := utl_raw.concat( t_keys, t_sum );
    end loop;
    t_keys := utl_raw.substr( t_keys, 1, t_key_length ); 
    t_key := utl_raw.substr( t_keys, 1, t_key_bits / 8 );
    t_rv := utl_raw.concat( t_salt, utl_raw.substr( t_keys, -2, 2 ) );
--
    for i in 0 .. trunc( ( dbms_lob.getlength( p_src ) - 1 ) / 16 )
    loop
      t_block := dbms_lob.substr( p_src, 16, i * 16 + 1 );
      t_len := utl_raw.length( t_block );
      if t_len < 16
      then 
        t_block := utl_raw.concat( t_block, utl_raw.copies( '00', 16 - t_len ) );
      end if;
      t_iv := utl_raw.reverse( to_char( i + 1, 'fm000000000000000000000000000000x' ) ); 
      dbms_lob.writeappend( t_rv, t_len, dbms_crypto.encrypt( t_block, dbms_crypto.ENCRYPT_AES256 + dbms_crypto.CHAIN_CFB + dbms_crypto.PAD_NONE, t_key, t_iv ) );
    end loop;
--
    dbms_lob.createtemporary( t_tmp, true );
    dbms_lob.copy( t_tmp, t_rv, dbms_lob.getlength( p_src ), 1, t_key_bits / 16 + 2 + 1 );
    t_mac := dbms_crypto.mac( t_tmp, dbms_crypto.HMAC_SH1, utl_raw.substr( t_keys, 1 + t_key_bits / 8, t_key_bits / 8 ) ); 
    dbms_lob.writeappend( t_rv, 10, t_mac );
    dbms_lob.freetemporary( t_tmp );
    return t_rv; 
  end;
--
  procedure add1file
    ( p_zipped_blob in out blob
    , p_name varchar2
    , p_content blob
    , p_password varchar2 := null
    )
  is
    t_now date;
    t_blob blob;
    t_len integer;
    t_clen integer;
    t_crc32 raw(4) := hextoraw( '00000000' );
    t_compressed boolean := false;
    t_encrypted boolean := false;
    t_name raw(32767);
    t_extra raw(11);
  begin
    t_now := sysdate;
    t_len := nvl( dbms_lob.getlength( p_content ), 0 );
    if t_len > 0
    then
      dbms_lob.createtemporary( t_blob, true ); 
      dbms_lob.copy( t_blob, utl_compress.lz_compress( p_content ), dbms_lob.lobmaxsize , 1, 11 );
      t_clen := dbms_lob.getlength( t_blob ) - 8;
      t_compressed := t_clen < t_len;
      t_crc32 := dbms_lob.substr( t_blob, 4, t_clen + 1 );
      dbms_lob.trim( t_blob, t_clen );
    end if;
    if not t_compressed
    then 
      t_clen := t_len;
      t_blob := p_content;
    end if;
--
    if p_zipped_blob is null
    then
      dbms_lob.createtemporary( p_zipped_blob, true );
    end if;
--
    if p_password is not null and t_len > 0
    then
      t_encrypted := true;
      t_crc32 := hextoraw( '00000000' );
      t_extra := hextoraw( '019907000200414503' || case when t_compressed
                                                     then '0800' -- deflate
                                                     else '0000' -- stored
                                                   end
                         );
      t_blob := encrypt( p_password, t_blob ); 
      t_clen := dbms_lob.getlength( t_blob );
    end if;
    t_name := utl_i18n.string_to_raw( p_name, 'AL32UTF8' );
    dbms_lob.append( p_zipped_blob
                   , utl_raw.concat( utl_raw.concat( c_LOCAL_FILE_HEADER -- Local file header signature
                                                   , hextoraw( '3300' )  -- version 5.1
                                                   )
                                   , case when t_encrypted
                                       then hextoraw( '01' ) -- encrypted
                                       else hextoraw( '00' ) 
                                     end 
                                   , case when t_name = utl_i18n.string_to_raw( p_name, 'US8PC437' )
                                       then hextoraw( '00' )
                                       else hextoraw( '08' ) -- set Language encoding flag (EFS)
                                     end 
                                   , case when t_encrypted
                                       then '6300'
                                       else
                                         case when t_compressed
                                           then hextoraw( '0800' ) -- deflate
                                           else hextoraw( '0000' ) -- stored
                                         end
                                     end
                                   , little_endian( to_number( to_char( t_now, 'ss' ) ) / 2
                                                  + to_number( to_char( t_now, 'mi' ) ) * 32
                                                  + to_number( to_char( t_now, 'hh24' ) ) * 2048
                                                  , 2
                                                  ) -- File last modification time
                                   , little_endian( to_number( to_char( t_now, 'dd' ) )
                                                  + to_number( to_char( t_now, 'mm' ) ) * 32
                                                  + ( to_number( to_char( t_now, 'yyyy' ) ) - 1980 ) * 512
                                                  , 2
                                                  ) -- File last modification date
                                   , t_crc32 -- CRC-32
                                   , little_endian( t_clen )                      -- compressed size
                                   , little_endian( t_len )                       -- uncompressed size
                                   , little_endian( utl_raw.length( t_name ), 2 ) -- File name length
                                   , little_endian( nvl( utl_raw.length( t_extra ), 0 ), 2 ) -- Extra field length
                                   , utl_raw.concat( t_name                       -- File name
                                                   , t_extra
                                                   )
                                   )
                   );
    if t_len > 0
    then                   
      dbms_lob.copy( p_zipped_blob, t_blob, t_clen, dbms_lob.getlength( p_zipped_blob ) + 1, 1 ); -- (compressed) content
    end if;
    dbms_lob.freetemporary( t_blob );
  end;
--
  procedure finish_zip( p_zipped_blob in out blob )
  is
    t_cnt pls_integer := 0;
    t_offs integer;
    t_offs_dir_header integer;
    t_offs_end_header integer;
    t_comment raw(32767) := utl_raw.cast_to_raw( 'Implementation by Anton Scheffer' );
    t_len pls_integer;
  begin
    t_offs_dir_header := dbms_lob.getlength( p_zipped_blob );
    t_offs := 1;
    while dbms_lob.substr( p_zipped_blob, utl_raw.length( c_LOCAL_FILE_HEADER ), t_offs ) = c_LOCAL_FILE_HEADER
    loop
      t_cnt := t_cnt + 1;
      t_len := blob2num( p_zipped_blob, 2, t_offs + 28 );
      dbms_lob.append( p_zipped_blob
                     , utl_raw.concat( hextoraw( '504B0102' )      -- Central directory file header signature
                                     , hextoraw( '3F00' )          -- version 6.3
                                     , dbms_lob.substr( p_zipped_blob, 26, t_offs + 4 )
                                     , hextoraw( '0000' )          -- File comment length
                                     , hextoraw( '0000' )          -- Disk number where file starts
                                     , hextoraw( '0000' )          -- Internal file attributes => 
                                                                   --     0000 binary file
                                                                   --     0100 (ascii)text file
                                     , case
                                         when dbms_lob.substr( p_zipped_blob
                                                             , 1
                                                             , t_offs + 30 + blob2num( p_zipped_blob, 2, t_offs + 26 ) - 1
                                                             ) in ( hextoraw( '2F' ) -- /
                                                                  , hextoraw( '5C' ) -- \
                                                                  )
                                         then hextoraw( '10000000' ) -- a directory/folder
                                         else hextoraw( '2000B681' ) -- a file
                                       end                         -- External file attributes
                                     , little_endian( t_offs - 1 ) -- Relative offset of local file header
                                     , dbms_lob.substr( p_zipped_blob
                                                      , blob2num( p_zipped_blob, 2, t_offs + 26 ) + t_len
                                                      , t_offs + 30
                                                      ) -- File name + extra data field
                                     )
                     );
      t_offs := t_offs + 30 + blob2num( p_zipped_blob, 4, t_offs + 18 )  -- compressed size
                            + blob2num( p_zipped_blob, 2, t_offs + 26 )  -- File name length 
                            + blob2num( p_zipped_blob, 2, t_offs + 28 ); -- Extra field length
    end loop;
    t_offs_end_header := dbms_lob.getlength( p_zipped_blob );
    dbms_lob.append( p_zipped_blob
                   , utl_raw.concat( c_END_OF_CENTRAL_DIRECTORY                                -- End of central directory signature
                                   , hextoraw( '0000' )                                        -- Number of this disk
                                   , hextoraw( '0000' )                                        -- Disk where central directory starts
                                   , little_endian( t_cnt, 2 )                                 -- Number of central directory records on this disk
                                   , little_endian( t_cnt, 2 )                                 -- Total number of central directory records
                                   , little_endian( t_offs_end_header - t_offs_dir_header )    -- Size of central directory
                                   , little_endian( t_offs_dir_header )                        -- Offset of start of central directory, relative to start of archive
                                   , little_endian( nvl( utl_raw.length( t_comment ), 0 ), 2 ) -- ZIP file comment length
                                   , t_comment
                                   )
                   );
  end;
--
  procedure save_zip
    ( p_zipped_blob blob
    , p_dir varchar2 := 'MY_DIR'
    , p_filename varchar2 := 'my.zip'
    )
  is
    t_fh utl_file.file_type;
    t_len pls_integer := 32767;
  begin
    t_fh := utl_file.fopen( p_dir, p_filename, 'wb' );
    for i in 0 .. trunc( ( dbms_lob.getlength( p_zipped_blob ) - 1 ) / t_len )
    loop
      utl_file.put_raw( t_fh, dbms_lob.substr( p_zipped_blob, t_len, i * t_len + 1 ) );
    end loop;
    utl_file.fclose( t_fh );
  end;
--
end;
/