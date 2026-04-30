export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  __InternalSupabase: { PostgrestVersion: '14.5' }
  public: {
    Tables: {
      event_attendance: {
        Row: {
          arrived_at: string | null
          cancelled_reason: string | null
          cancelled_same_day: boolean
          event_id: string
          id: string
          marked_by: string | null
          no_show: boolean
          notes: string | null
          rsvp_at: string | null
          rsvp_status: string
          user_id: string
        }
        Insert: {
          arrived_at?: string | null
          cancelled_reason?: string | null
          cancelled_same_day?: boolean
          event_id: string
          id?: string
          marked_by?: string | null
          no_show?: boolean
          notes?: string | null
          rsvp_at?: string | null
          rsvp_status?: string
          user_id: string
        }
        Update: {
          arrived_at?: string | null
          cancelled_reason?: string | null
          cancelled_same_day?: boolean
          event_id?: string
          id?: string
          marked_by?: string | null
          no_show?: boolean
          notes?: string | null
          rsvp_at?: string | null
          rsvp_status?: string
          user_id?: string
        }
        Relationships: []
      }
      events: {
        Row: {
          created_at: string
          created_by: string | null
          cycle_number: number | null
          ends_at: string | null
          group_id: string
          host_id: string | null
          id: string
          location: string | null
          notes: string | null
          rsvp_deadline: string | null
          rules_evaluated_at: string | null
          starts_at: string
          status: string
          title: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          cycle_number?: number | null
          ends_at?: string | null
          group_id: string
          host_id?: string | null
          id?: string
          location?: string | null
          notes?: string | null
          rsvp_deadline?: string | null
          rules_evaluated_at?: string | null
          starts_at: string
          status?: string
          title?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          cycle_number?: number | null
          ends_at?: string | null
          group_id?: string
          host_id?: string | null
          id?: string
          location?: string | null
          notes?: string | null
          rsvp_deadline?: string | null
          rules_evaluated_at?: string | null
          starts_at?: string
          status?: string
          title?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      expense_shares: {
        Row: { amount: number; expense_id: string; id: string; user_id: string }
        Insert: { amount: number; expense_id: string; id?: string; user_id: string }
        Update: { amount?: number; expense_id?: string; id?: string; user_id?: string }
        Relationships: []
      }
      expenses: {
        Row: {
          amount: number
          created_at: string
          description: string
          event_id: string | null
          expense_date: string
          group_id: string
          id: string
          notes: string | null
          paid_by: string
          split_type: string
          updated_at: string
        }
        Insert: {
          amount: number
          created_at?: string
          description: string
          event_id?: string | null
          expense_date?: string
          group_id: string
          id?: string
          notes?: string | null
          paid_by: string
          split_type?: string
          updated_at?: string
        }
        Update: {
          amount?: number
          created_at?: string
          description?: string
          event_id?: string | null
          expense_date?: string
          group_id?: string
          id?: string
          notes?: string | null
          paid_by?: string
          split_type?: string
          updated_at?: string
        }
        Relationships: []
      }
      fines: {
        Row: {
          amount: number
          appeal_vote_id: string | null
          auto_generated: boolean
          created_at: string
          details: Json | null
          event_id: string | null
          group_id: string
          id: string
          issued_by: string | null
          paid: boolean
          paid_at: string | null
          paid_to_fund: boolean
          reason: string
          rule_id: string | null
          updated_at: string
          user_id: string
          waived: boolean
          waived_at: string | null
          waived_reason: string | null
        }
        Insert: {
          amount: number
          appeal_vote_id?: string | null
          auto_generated?: boolean
          created_at?: string
          details?: Json | null
          event_id?: string | null
          group_id: string
          id?: string
          issued_by?: string | null
          paid?: boolean
          paid_at?: string | null
          paid_to_fund?: boolean
          reason: string
          rule_id?: string | null
          updated_at?: string
          user_id: string
          waived?: boolean
          waived_at?: string | null
          waived_reason?: string | null
        }
        Update: {
          amount?: number
          appeal_vote_id?: string | null
          auto_generated?: boolean
          created_at?: string
          details?: Json | null
          event_id?: string | null
          group_id?: string
          id?: string
          issued_by?: string | null
          paid?: boolean
          paid_at?: string | null
          paid_to_fund?: boolean
          reason?: string
          rule_id?: string | null
          updated_at?: string
          user_id?: string
          waived?: boolean
          waived_at?: string | null
          waived_reason?: string | null
        }
        Relationships: []
      }
      group_members: {
        Row: {
          active: boolean
          display_name_override: string | null
          group_id: string
          id: string
          joined_at: string
          on_committee: boolean
          role: string
          turn_order: number | null
          user_id: string
        }
        Insert: {
          active?: boolean
          display_name_override?: string | null
          group_id: string
          id?: string
          joined_at?: string
          on_committee?: boolean
          role?: string
          turn_order?: number | null
          user_id: string
        }
        Update: {
          active?: boolean
          display_name_override?: string | null
          group_id?: string
          id?: string
          joined_at?: string
          on_committee?: boolean
          role?: string
          turn_order?: number | null
          user_id?: string
        }
        Relationships: []
      }
      groups: {
        Row: {
          block_unpaid_attendance: boolean
          committee_required_for_appeals: boolean
          created_at: string
          created_by: string
          currency: string
          default_day_of_week: number | null
          default_location: string | null
          default_start_time: string | null
          description: string | null
          event_label: string
          fund_admin: string | null
          fund_balance: number
          fund_enabled: boolean
          fund_min_participants: number | null
          fund_target: number | null
          fund_target_label: string | null
          id: string
          invite_code: string
          name: string
          rotation_enabled: boolean
          timezone: string
          updated_at: string
          vote_duration_hours: number
          voting_quorum: number
          voting_threshold: number
        }
        Insert: {
          block_unpaid_attendance?: boolean
          committee_required_for_appeals?: boolean
          created_at?: string
          created_by: string
          currency?: string
          default_day_of_week?: number | null
          default_location?: string | null
          default_start_time?: string | null
          description?: string | null
          event_label?: string
          fund_admin?: string | null
          fund_balance?: number
          fund_enabled?: boolean
          fund_min_participants?: number | null
          fund_target?: number | null
          fund_target_label?: string | null
          id?: string
          invite_code?: string
          name: string
          rotation_enabled?: boolean
          timezone?: string
          updated_at?: string
          vote_duration_hours?: number
          voting_quorum?: number
          voting_threshold?: number
        }
        Update: {
          block_unpaid_attendance?: boolean
          committee_required_for_appeals?: boolean
          created_at?: string
          created_by?: string
          currency?: string
          default_day_of_week?: number | null
          default_location?: string | null
          default_start_time?: string | null
          description?: string | null
          event_label?: string
          fund_admin?: string | null
          fund_balance?: number
          fund_enabled?: boolean
          fund_min_participants?: number | null
          fund_target?: number | null
          fund_target_label?: string | null
          id?: string
          invite_code?: string
          name?: string
          rotation_enabled?: boolean
          timezone?: string
          updated_at?: string
          vote_duration_hours?: number
          voting_quorum?: number
          voting_threshold?: number
        }
        Relationships: []
      }
      payments: {
        Row: {
          amount: number
          created_at: string
          from_user: string
          group_id: string
          id: string
          note: string | null
          paid_at: string
          to_user: string
        }
        Insert: {
          amount: number
          created_at?: string
          from_user: string
          group_id: string
          id?: string
          note?: string | null
          paid_at?: string
          to_user: string
        }
        Update: {
          amount?: number
          created_at?: string
          from_user?: string
          group_id?: string
          id?: string
          note?: string | null
          paid_at?: string
          to_user?: string
        }
        Relationships: []
      }
      pot_entries: {
        Row: {
          amount: number
          id: string
          paid_at: string | null
          paid_to_winner: boolean
          pot_id: string
          user_id: string
        }
        Insert: {
          amount: number
          id?: string
          paid_at?: string | null
          paid_to_winner?: boolean
          pot_id: string
          user_id: string
        }
        Update: {
          amount?: number
          id?: string
          paid_at?: string | null
          paid_to_winner?: boolean
          pot_id?: string
          user_id?: string
        }
        Relationships: []
      }
      pots: {
        Row: {
          buy_in: number
          closed_at: string | null
          created_at: string
          created_by: string | null
          currency: string
          event_id: string | null
          group_id: string
          id: string
          name: string
          notes: string | null
          status: string
          updated_at: string
          winner_id: string | null
        }
        Insert: {
          buy_in: number
          closed_at?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          event_id?: string | null
          group_id: string
          id?: string
          name: string
          notes?: string | null
          status?: string
          updated_at?: string
          winner_id?: string | null
        }
        Update: {
          buy_in?: number
          closed_at?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          event_id?: string | null
          group_id?: string
          id?: string
          name?: string
          notes?: string | null
          status?: string
          updated_at?: string
          winner_id?: string | null
        }
        Relationships: []
      }
      profiles: {
        Row: {
          avatar_url: string | null
          created_at: string
          display_name: string
          id: string
          phone: string | null
          updated_at: string
        }
        Insert: {
          avatar_url?: string | null
          created_at?: string
          display_name: string
          id: string
          phone?: string | null
          updated_at?: string
        }
        Update: {
          avatar_url?: string | null
          created_at?: string
          display_name?: string
          id?: string
          phone?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      rules: {
        Row: {
          action: Json
          approved_via_vote_id: string | null
          code: string | null
          created_at: string
          description: string | null
          enabled: boolean
          exceptions: Json
          group_id: string
          id: string
          proposed_by: string | null
          status: string
          title: string
          trigger: Json
          updated_at: string
        }
        Insert: {
          action?: Json
          approved_via_vote_id?: string | null
          code?: string | null
          created_at?: string
          description?: string | null
          enabled?: boolean
          exceptions?: Json
          group_id: string
          id?: string
          proposed_by?: string | null
          status?: string
          title: string
          trigger: Json
          updated_at?: string
        }
        Update: {
          action?: Json
          approved_via_vote_id?: string | null
          code?: string | null
          created_at?: string
          description?: string | null
          enabled?: boolean
          exceptions?: Json
          group_id?: string
          id?: string
          proposed_by?: string | null
          status?: string
          title?: string
          trigger?: Json
          updated_at?: string
        }
        Relationships: []
      }
      vote_ballots: {
        Row: { cast_at: string; choice: string; id: string; user_id: string; vote_id: string }
        Insert: { cast_at?: string; choice: string; id?: string; user_id: string; vote_id: string }
        Update: { cast_at?: string; choice?: string; id?: string; user_id?: string; vote_id?: string }
        Relationships: []
      }
      votes: {
        Row: {
          closes_at: string
          committee_only: boolean
          created_at: string
          created_by: string
          description: string | null
          group_id: string
          id: string
          opens_at: string
          payload: Json | null
          quorum: number
          result: Json | null
          status: string
          subject_id: string | null
          subject_type: string
          threshold: number
          title: string
          updated_at: string
        }
        Insert: {
          closes_at: string
          committee_only?: boolean
          created_at?: string
          created_by: string
          description?: string | null
          group_id: string
          id?: string
          opens_at?: string
          payload?: Json | null
          quorum?: number
          result?: Json | null
          status?: string
          subject_id?: string | null
          subject_type: string
          threshold?: number
          title: string
          updated_at?: string
        }
        Update: {
          closes_at?: string
          committee_only?: boolean
          created_at?: string
          created_by?: string
          description?: string | null
          group_id?: string
          id?: string
          opens_at?: string
          payload?: Json | null
          quorum?: number
          result?: Json | null
          status?: string
          subject_id?: string | null
          subject_type?: string
          threshold?: number
          title?: string
          updated_at?: string
        }
        Relationships: []
      }
    }
    Views: {
      group_balances: {
        Row: { balance: number | null; group_id: string | null; user_id: string | null }
        Relationships: []
      }
    }
    Functions: {
      check_in_attendee: {
        Args: { p_arrived_at: string | null; p_event_id: string; p_user_id: string }
        Returns: undefined
      }
      close_pot: {
        Args: { p_pot_id: string; p_winner_id: string }
        Returns: Database['public']['Tables']['pots']['Row']
      }
      close_vote: {
        Args: { p_vote_id: string }
        Returns: Database['public']['Tables']['votes']['Row']
      }
      create_event: {
        Args: {
          p_cycle_number: number | null
          p_ends_at: string | null
          p_group_id: string
          p_host_id: string | null
          p_location: string | null
          p_rsvp_deadline: string | null
          p_starts_at: string
          p_title: string | null
        }
        Returns: Database['public']['Tables']['events']['Row']
      }
      create_expense_with_shares: {
        Args: {
          p_amount: number
          p_description: string
          p_event_id: string | null
          p_expense_date: string | null
          p_group_id: string
          p_notes: string | null
          p_shares: Json
          p_split_type: string
        }
        Returns: Database['public']['Tables']['expenses']['Row']
      }
      create_group_with_admin: {
        Args: {
          p_currency: string
          p_default_day: number | null
          p_default_location: string | null
          p_default_time: string | null
          p_description: string | null
          p_event_label: string
          p_fund_enabled: boolean
          p_name: string
          p_timezone: string
          p_voting_quorum: number
          p_voting_threshold: number
        }
        Returns: Database['public']['Tables']['groups']['Row']
      }
      create_vote: {
        Args: {
          p_committee_only: boolean
          p_description: string | null
          p_group_id: string
          p_payload: Json | null
          p_subject_id: string | null
          p_subject_type: string
          p_title: string
        }
        Returns: Database['public']['Tables']['votes']['Row']
      }
      evaluate_event_rules: { Args: { p_event_id: string }; Returns: number }
      is_group_admin: { Args: { gid: string; uid: string }; Returns: boolean }
      is_group_committee: { Args: { gid: string; uid: string }; Returns: boolean }
      is_group_member: { Args: { gid: string; uid: string }; Returns: boolean }
      join_group_by_code: {
        Args: { p_code: string }
        Returns: Database['public']['Tables']['groups']['Row']
      }
      next_host_for_group: {
        Args: { p_cycle: number; p_group_id: string }
        Returns: string
      }
      pay_fine: { Args: { p_fine_id: string }; Returns: undefined }
      propose_rule: {
        Args: {
          p_action: Json
          p_committee_only: boolean
          p_description: string | null
          p_exceptions: Json
          p_group_id: string
          p_title: string
          p_trigger: Json
        }
        Returns: Database['public']['Tables']['rules']['Row']
      }
      set_turn_order: {
        Args: { p_group_id: string; p_user_ids: string[] }
        Returns: undefined
      }
    }
    Enums: Record<string, never>
    CompositeTypes: Record<string, never>
  }
}
