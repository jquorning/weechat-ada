--  SPDX-License-Identifier: Apache-2.0
--
--  Copyright (c) 2020 onox <denkpadje@gmail.com>
--
--  Licensed under the Apache License, Version 2.0 (the "License");
--  you may not use this file except in compliance with the License.
--  You may obtain a copy of the License at
--
--      http://www.apache.org/licenses/LICENSE-2.0
--
--  Unless required by applicable law or agreed to in writing, software
--  distributed under the License is distributed on an "AS IS" BASIS,
--  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
--  See the License for the specific language governing permissions and
--  limitations under the License.

with Ada.Calendar.Time_Zones;
with Ada.Characters.Handling;
with Ada.Exceptions;
with Ada.Strings.Maps;
with Ada.Unchecked_Conversion;

package body WeeChat is

   use Interfaces.C.Strings;

   Plugin : Plugin_Ptr;

   package SM renames Ada.Strings.Maps;

   function Trim (Value : String) return String is
     (SF.Trim (Value, SM.Null_Set, SM.To_Set (L1.LF)));

   function Split
     (Value     : String;
      Separator : String := " ";
      Maximum   : Natural := 0) return String_List
   is
      Lines : constant String := Trim (Value);

      Index : Positive := Lines'First;

      Auto_Count : constant Positive := SF.Count (Lines, Separator) + 1;
      Count : constant Positive :=
        (if Maximum > 0 then Positive'Min (Maximum, Auto_Count) else Auto_Count);
   begin
      return Result : String_List (1 .. Count) do
         for I in Result'First .. Result'Last - 1 loop
            declare
               Next_Index : constant Positive := SF.Index (Lines, Separator, Index);
            begin
               Result (I) := SU.To_Unbounded_String (Lines (Index .. Next_Index - 1));
               Index := Next_Index + 1;
            end;
         end loop;
         Result (Result'Last) := SU.To_Unbounded_String (Lines (Index .. Lines'Last));
      end return;
   end Split;

   procedure Send_Message (Server, Recipient, Message : String) is
      Signal_Message : chars_ptr := New_String
        (Server & ";" & Recipient & ";priority_high,user_message;;" & Message);

      function Convert is new Ada.Unchecked_Conversion (chars_ptr, Void_Ptr);
   begin
      Send_Signal ("irc_input_send", String_Type, Convert (Signal_Message));
      Free (Signal_Message);
   exception
      when others =>
         Free (Signal_Message);
         raise;
   end Send_Message;

   function Get_Nick (Host : String) return String is
      Sender : constant String := SU.To_String (Split (Host, Separator => "!", Maximum => 2) (1));
   begin
      return Sender (Sender'First + 1 .. Sender'Last);
   end Get_Nick;

   procedure Print (Prefix : Prefix_Kind; Message : String) is
      package CH renames Ada.Characters.Handling;

      Prefix_String  : constant chars_ptr := Plugin.Prefix (CH.To_Lower (Prefix'Image) & L1.NUL);
      Message_String : constant C_String  := Value (Prefix_String) & Message & L1.NUL;
   begin
      Plugin.Printf_Date_Tags
        (System.Null_Address, 0, Null_Ptr, Message_String);
   end Print;

   procedure Print (Prefix : String; Message : String) is
   begin
      Plugin.Printf_Date_Tags
        (System.Null_Address, 0, Null_Ptr, Prefix & L1.HT & Message & L1.NUL);
   end Print;

   procedure Print (Message : String) is
   begin
      Print (" ", Message);
   end Print;

   procedure Log (Message : String) is
   begin
      Plugin.Log_Printf (Message & L1.NUL);
   end Log;

   procedure Print_Error (Value : Ada.Exceptions.Exception_Occurrence) is
   begin
      Print (Error, Ada.Exceptions.Exception_Information (Value));
   end Print_Error;

   function Command_Callback
     (Callback : On_Command_Callback;
      Data     : Void_Ptr;
      Buffer   : Buffer_Ptr;
      Argc     : int;
      Argv     : access chars_ptr;
      Argv_EOL : access chars_ptr) return Callback_Result
   is
      Raw_Arguments : chars_ptr_array (1 .. size_t (Argc))
        with Address => (if Argv /= null then Argv.all'Address else System.Null_Address),
             Import  => True;

      function Get_Argument (Index : Positive) return String
        with Pre => Index <= Integer (Argc) or else
          raise Constraint_Error with "Index" & Index'Image & " not in 1 .." & Argc'Image;

      function Get_Argument (Index : Positive) return String is
        (Value (Raw_Arguments (size_t (Index))));

      Arguments : String_List (1 .. Raw_Arguments'Length);
   begin
      for Index in Arguments'Range loop
         Arguments (Index) := SU.To_Unbounded_String (Get_Argument (Index));
      end loop;

      return Callback (Data, Buffer, Arguments);
   exception
      when E : others =>
         Print_Error (E);
         return Error;
   end Command_Callback;

   function Command_Run_Callback
     (Callback : On_Command_Run_Callback;
      Data     : Void_Ptr;
      Buffer   : Buffer_Ptr;
      Command  : chars_ptr) return Callback_Result is
   begin
      return Callback (Data, Buffer, Value (Command));
   exception
      when E : others =>
         Print_Error (E);
         return Error;
   end Command_Run_Callback;

   function Modifier_Callback
     (Callback      : On_Modifier_Callback;
      Data          : Void_Ptr;
      Modifier      : chars_ptr;
      Modifier_Data : chars_ptr;
      Text          : chars_ptr) return chars_ptr is
   begin
      return New_String (Callback (Data, Value (Modifier), Value (Modifier_Data), Value (Text)));
   exception
      when E : others =>
         Print_Error (E);
         return Text;
   end Modifier_Callback;

   function Print_Callback
     (Callback   : On_Print_Callback;
      Data       : Void_Ptr;
      Buffer     : Buffer_Ptr;
      Date       : Time_T;
      Tagc       : int;
      Tagv       : access chars_ptr;
      Displayed  : int;
      Highlight  : int;
      Prefix     : chars_ptr;
      Message    : chars_ptr) return Callback_Result
   is
      Raw_Tags : chars_ptr_array (1 .. size_t (Tagc))
        with Address => (if Tagv /= null then Tagv.all'Address else System.Null_Address),
             Import  => True;

      function Get_Tag (Index : Positive) return String
        with Pre => Index <= Integer (Tagc) or else
          raise Constraint_Error with "Index" & Index'Image & " not in 1 .." & Tagc'Image;

      function Get_Tag (Index : Positive) return String is
        (Value (Raw_Tags (size_t (Index))));

      use Ada.Calendar;

      Time_Epoch  : constant Time := Time_Of (Year => 1970, Month => 1, Day => 1);
      Time_Offset : constant Duration := Duration (Time_Zones.UTC_Time_Offset (Time_Epoch)) * 60;

      Tags : String_List (1 .. Raw_Tags'Length);
   begin
      for Index in Tags'Range loop
         Tags (Index) := SU.To_Unbounded_String (Get_Tag (Index));
      end loop;

      return Callback (Data, Buffer, Time_Epoch + Time_Offset + Duration (Date),
        Tags, Displayed = 1, Highlight = 1, Value (Prefix), Value (Message));
   exception
      when E : others =>
         Print_Error (E);
         return Error;
   end Print_Callback;

   function Signal_Callback
     (Callback    : On_Signal_Callback;
      Data        : Void_Ptr;
      Signal      : chars_ptr;
      Type_Data   : chars_ptr;
      Signal_Data : Void_Ptr) return Callback_Result
   is
      Type_String : constant String := Value (Type_Data);

      Kind : Data_Kind;
   begin
      if Type_String = "string" then
         Kind := String_Type;
      elsif Type_String = "int" then
         Kind := Int_Type;
      elsif Type_String = "pointer" then
         Kind := Pointer_Type;
      else
         raise Constraint_Error with "Invalid signal type";
      end if;

      return Callback (Data, Value (Signal), Kind, Signal_Data);
   exception
      when E : others =>
         Print_Error (E);
         return Error;
   end Signal_Callback;

   function Timer_Callback
     (Callback        : On_Timer_Callback;
      Data            : Void_Ptr;
      Remaining_Calls : int) return Callback_Result is
   begin
      return Callback (Data, Integer (Remaining_Calls));
   exception
      when E : others =>
         Print_Error (E);
         return Error;
   end Timer_Callback;

   -----------------------------------------------------------------------------

   procedure Add_Command
     (Command               : String;
      Description           : String;
      Arguments             : String;
      Arguments_Description : String;
      Completion            : String;
      Callback              : On_Command_Callback;
      Data                  : Void_Ptr := Null_Void)
   is
      Result : Hook_Ptr;
   begin
      Result := Plugin.Hook_Command
        (Plugin,
         Command & L1.NUL,
         Description & L1.NUL,
         Arguments & L1.NUL,
         Arguments_Description & L1.NUL,
         Completion & L1.NUL,
         Command_Callback'Access,
         Callback,
         Data);
      pragma Assert (Result /= null);
   end Add_Command;

   procedure On_Command_Run
     (Command  : String;
      Callback : On_Command_Run_Callback;
      Data     : Void_Ptr := Null_Void)
   is
      Result : Hook_Ptr;
   begin
      Result := Plugin.Hook_Command_Run
        (Plugin,
         Command & L1.NUL,
         Command_Run_Callback'Access,
         Callback,
         Data);
      pragma Assert (Result /= null);
   end On_Command_Run;

   function Run_Command
     (Buffer  : Buffer_Ptr;
      Message : String) return Boolean
   is
      Result : Callback_Result;
   begin
      Result := Plugin.Command (Plugin, Buffer, Message & L1.NUL);
      pragma Assert (Result /= Eat);
      return Result /= Error;
   end Run_Command;

   procedure Run_Command
     (Buffer  : Buffer_Ptr;
      Message : String) is
   begin
      if not Run_Command (Buffer, Message) then
         raise Program_Error;
      end if;
   end Run_Command;

   procedure On_Modifier
     (Modifier : String;
      Callback : On_Modifier_Callback;
      Data     : Void_Ptr := Null_Void)
   is
      Result : Hook_Ptr;
   begin
      Result := Plugin.Hook_Modifier
        (Plugin, Modifier & L1.NUL, Modifier_Callback'Access, Callback, Data);
      pragma Assert (Result /= null);
   end On_Modifier;

   procedure On_Print
     (Buffer       : Buffer_Ptr;
      Tags         : String;
      Message      : String;
      Strip_Colors : Boolean;
      Callback     : On_Print_Callback;
      Data         : Void_Ptr := Null_Void)
   is
      Result : Hook_Ptr;
   begin
      Result := Plugin.Hook_Print
        (Plugin,  Buffer, Tags & L1.NUL, Message & L1.NUL,
         (if Strip_Colors then 1 else 0), Print_Callback'Access, Callback, Data);
      pragma Assert (Result /= null);
   end On_Print;

   procedure On_Signal
     (Signal   : String;
      Callback : On_Signal_Callback;
      Data     : Void_Ptr := Null_Void)
   is
      Result : Hook_Ptr;
   begin
      Result := Plugin.Hook_Signal
        (Plugin, (if Signal'Length > 0 then Signal else "*") & L1.NUL,
         Signal_Callback'Access, Callback, Data);
      pragma Assert (Result /= null);
   end On_Signal;

   procedure Send_Signal
     (Signal      : String;
      Kind        : Data_Kind;
      Signal_Data : Void_Ptr)
   is
      package CH renames Ada.Characters.Handling;

      Data_Kind : constant String := CH.To_Lower (Kind'Image);

      Result : Callback_Result;
   begin
      Result := Plugin.Hook_Signal_Send
        (Signal & L1.NUL, Data_Kind (Data_Kind'First .. Data_Kind'Last - 5) & L1.NUL,
         Signal_Data);
   end Send_Signal;

   function Set_Timer
     (Interval     : Duration;
      Align_Second : Natural;
      Max_Calls    : Natural;
      Callback     : On_Timer_Callback;
      Data         : Void_Ptr := Null_Void) return Timer
   is
      Result : Hook_Ptr;
   begin
      Result := Plugin.Hook_Timer
        (Plugin, long (Interval * 1e3), int (Align_Second), int (Max_Calls),
         Timer_Callback'Access, Callback, Data);
      pragma Assert (Result /= null);
      return Timer (Result);
   end Set_Timer;

   procedure Cancel_Timer (Object : Timer) is
   begin
      Plugin.Unhook (Hook_Ptr (Object));
   end Cancel_Timer;

   procedure Set_Title (Title : String) is
   begin
      Plugin.Window_Set_Title (Title & L1.NUL);
   end Set_Title;

   function Get_Info (Name, Arguments : String) return String is
      Args : chars_ptr := New_String (Arguments);
   begin
      return Result : constant String := Value (Plugin.Info_Get (Plugin, Name & L1.NUL, Args)) do
         Free (Args);
      end return;
   exception
      when others =>
         Free (Args);
         raise;
   end Get_Info;

   function Get_Info (Name : String) return String is
     (Value (Plugin.Info_Get (Plugin, Name & L1.NUL, Null_Ptr)));

   -----------------------------------------------------------------------------

   Plugin_Initialize, Plugin_Finalize : Plugin_Callback;

   Meta_Data : Plugin_Meta_Data;

   function Plugin_Init
     (Plugin : Plugin_Ptr;
      Argc   : int;
      Argv   : System.Address) return Callback_Result is
   begin
      WeeChat.Plugin := Plugin;

      if Plugin_Initialize = null then
         raise Program_Error with "Plug-in not initialized with call to procedure Register";
      end if;

      Plugin.Name        := New_String (+Meta_Data.Name);
      Plugin.Author      := New_String (+Meta_Data.Author);
      Plugin.Description := New_String (+Meta_Data.Description);
      Plugin.Version     := New_String (+Meta_Data.Version);
      Plugin.License     := New_String (+Meta_Data.License);

      Plugin_Initialize.all;

      return OK;
   exception
      when E : others =>
         Print_Error (E);
         WeeChat.Plugin := null;
         return Error;
   end Plugin_Init;

   function Plugin_End (Plugin : Plugin_Ptr) return Callback_Result is
   begin
      Plugin_Finalize.all;
      WeeChat.Plugin := null;
      return OK;
   exception
      when E : others =>
         Print_Error (E);
         return Error;
   end Plugin_End;

   procedure Register
     (Name, Author, Description, Version, License : String;
      Initialize, Finalize                        : not null Plugin_Callback) is
   begin
      Meta_Data := (+Name, +Author, +Description, +Version, +License);

      Plugin_Initialize := Initialize;
      Plugin_Finalize   := Finalize;
   end Register;

end WeeChat;
